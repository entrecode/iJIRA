import AppKit
import Foundation
import Network
import Observation

/// Pollt Jira in festem Intervall, leitet aus Issues/Kommentaren/Changelog
/// Notification-Events ab und persistiert neue Einträge im `NotificationStore`.
///
/// Zuverlässigkeit im Dauerbetrieb (Menüleisten-Agent):
/// - `ProcessInfo`-Activity verhindert App Nap (sonst drosselt macOS den
///   Prozess nach Idle-Zeit und Timer feuern massiv verspätet).
/// - Aufwachen aus dem Ruhezustand und Netzwerk-Rückkehr starten den Loop
///   hart neu (`kick()`) — inklusive Abbruch eines evtl. festhängenden Requests.
/// - Ein Watchdog bricht jeden Sync nach spätestens 5 Minuten ab, damit der
///   Loop nie dauerhaft blockiert.
@MainActor
@Observable
final class SyncEngine {
    private(set) var isSyncing = false
    private(set) var lastError: String?
    private(set) var lastSyncedAt: Date?

    private let appState: AppState
    private let store: NotificationStore
    private let push: PushPresenter
    private var syncTask: Task<Void, Never>?
    private var currentInterval: TimeInterval = 90

    /// Soll der Loop laufen? Entkoppelt von `syncTask`, damit `kick()` nach
    /// einem Disconnect nicht versehentlich wieder startet.
    private var shouldBeRunning = false
    private var restartInFlight = false

    private var activity: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private let pathMonitor = NWPathMonitor()
    private var networkWasSatisfied = true

    private static let baseInterval: TimeInterval = 90
    private static let maxInterval: TimeInterval = 900 // 15 min
    private static let syncTimeout: TimeInterval = 300
    private static let baselineKey = "didEstablishBaseline"

    /// Beim allerersten Sync (frische Installation/neuer Account) werden
    /// Backlog-Einträge nur still in die Timeline geschrieben — kein Push,
    /// damit es keine Benachrichtigungsflut gibt.
    private var didEstablishBaseline: Bool {
        get { UserDefaults.standard.bool(forKey: Self.baselineKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.baselineKey) }
    }

    init(appState: AppState, store: NotificationStore, push: PushPresenter) {
        self.appState = appState
        self.store = store
        self.push = push
        installResilienceTriggers()
    }

    /// Beim Trennen zurücksetzen, damit ein neuer Account wieder still startet.
    func resetBaseline() {
        didEstablishBaseline = false
    }

    func start() {
        shouldBeRunning = true
        guard syncTask == nil else { return }
        beginActivity()
        startLoop()
    }

    func stop() {
        shouldBeRunning = false
        syncTask?.cancel()
        syncTask = nil
        currentInterval = Self.baseInterval
        endActivity()
    }

    /// Harter Neustart des Sync-Loops: bricht den laufenden Durchlauf samt
    /// in-flight Request ab und beginnt sofort frisch. Wird nach dem Aufwachen
    /// und bei Netzwerk-Rückkehr aufgerufen — genau die Momente, in denen ein
    /// alter Request tot sein kann und sofortige Aktualität gewünscht ist.
    func kick() {
        guard shouldBeRunning, !restartInFlight else { return }
        restartInFlight = true
        currentInterval = Self.baseInterval
        let old = syncTask
        syncTask = nil
        old?.cancel()
        Task {
            await old?.value
            restartInFlight = false
            guard shouldBeRunning, syncTask == nil else { return }
            startLoop()
        }
    }

    private func startLoop() {
        syncTask = Task {
            while !Task.isCancelled {
                await runGuardedSync()
                if Task.isCancelled { break }
                if lastError != nil {
                    currentInterval = min(currentInterval * 2, Self.maxInterval)
                } else {
                    currentInterval = Self.baseInterval
                }
                try? await Task.sleep(nanoseconds: UInt64(currentInterval * 1_000_000_000))
            }
        }
    }

    /// Führt einen Sync mit Watchdog aus: hängt trotz der Session-Timeouts
    /// etwas fest, wird nach `syncTimeout` hart abgebrochen statt den Loop
    /// zu blockieren. Cancel des Loops (kick/stop) reicht bis in den Sync durch.
    private func runGuardedSync() async {
        let sync = Task { await self.syncNow() }
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.syncTimeout * 1_000_000_000))
            sync.cancel()
        }
        await withTaskCancellationHandler {
            await sync.value
        } onCancel: {
            sync.cancel()
        }
        watchdog.cancel()
    }

    func syncNow() async {
        guard !isSyncing, let client = appState.currentClient() else { return }
        isSyncing = true
        defer { isSyncing = false }

        do {
            let issues = try await client.searchInvolvedIssues()
            var fresh: [JiraNotification] = []
            for issue in issues {
                fresh += await process(issue: issue, client: client)
            }
            let saved = store.save()
            lastError = nil
            lastSyncedAt = Date()

            // Erst-Sync still einlesen; ab dann neue Einträge pushen.
            if didEstablishBaseline {
                if saved {
                    push.presentBatch(fresh)
                }
            } else {
                // Historische Einträge direkt als gelesen markieren – kein Badge-Flood.
                fresh.forEach { $0.isRead = true }
                if store.save() {
                    didEstablishBaseline = true
                }
            }

            store.purgeOldNotifications()
        } catch is CancellationError {
            lastError = "Synchronisierung abgebrochen (Timeout)."
        } catch let error as URLError where error.code == .cancelled {
            lastError = "Synchronisierung abgebrochen (Timeout)."
        } catch {
            lastError = (error as? JiraError)?.userMessage ?? error.localizedDescription
        }
    }

    // MARK: - Resilience (Wake, Netzwerk, App Nap)

    private func installResilienceTriggers() {
        // Nach dem Aufwachen kurz warten (Netzwerk braucht einen Moment),
        // dann den Loop hart neu starten.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self?.kick()
            }
        }

        // Netzwerk kommt zurück (WLAN-Wechsel, VPN, Offline → Online) → sofort syncen.
        pathMonitor.pathUpdateHandler = { path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                if satisfied && !self.networkWasSatisfied {
                    self.kick()
                }
                self.networkWasSatisfied = satisfied
            }
        }
        pathMonitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    /// Verhindert App Nap, solange der Sync-Loop laufen soll — ohne den
    /// System-Ruhezustand zu blockieren (`AllowingIdleSystemSleep`).
    private func beginActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Periodischer Jira-Sync")
    }

    private func endActivity() {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
        activity = nil
    }

    // MARK: - Per-issue processing

    /// Verarbeitet ein Issue und gibt die neu eingefügten Notifications zurück.
    private func process(issue: IssueDTO, client: JiraClient) async -> [JiraNotification] {
        var inserted: [JiraNotification] = []
        let issueUpdated = JiraDate.parse(issue.fields.updated) ?? .distantPast
        let cursor = store.cursor(for: issue.key)

        // Unverändert seit letztem Sync? Dann sparen wir uns die Detail-Requests.
        if let cursor, issueUpdated <= cursor.lastSeenUpdated { return inserted }

        // Alles bis zum zuletzt gesehenen Stand gilt als historisch (kein Push,
        // direkt gelesen): beim ersten Kontakt mit dem Issue alles älter als 1 h
        // vor dem letzten Update, danach alles bis zum Cursor-Stand. Verhindert
        // u. a., dass bereits gepurgte alte Kommentare erneut als „neu" gepusht
        // werden, wenn ein altes Issue wieder aktiv wird.
        let historicalCutoff = cursor?.lastSeenUpdated ?? issueUpdated.addingTimeInterval(-3600)

        let myAccountId = appState.accountId
        var newestCommentId: String?

        var fetchFailed = false

        // Kommentare → eigene Timeline-Events (Dedup über Kommentar-ID).
        do {
            let comments = try await client.comments(issueKey: issue.key)
            newestCommentId = comments.first?.id
            for comment in comments {
                guard comment.author?.accountId != myAccountId else { continue } // eigene überspringen
                let created = JiraDate.parse(comment.created) ?? .distantPast
                let isHistorical = created <= historicalCutoff

                let author = comment.author?.displayName ?? "jemand"
                var adfJSON: String?
                if let body = comment.body, let data = try? JSONEncoder().encode(body) {
                    adfJSON = String(data: data, encoding: .utf8)
                }
                let notification = JiraNotification(
                    dedupKey: "comment:\(issue.key):\(comment.id)",
                    issueKey: issue.key,
                    issueSummary: issue.fields.summary,
                    kind: .comment,
                    title: "Neuer Kommentar von \(author)",
                    bodyPreview: String(comment.bodyText.prefix(280)),
                    actorName: author,
                    actorAvatarURLString: comment.author?.avatar48,
                    webURLString: appState.issueWebURL(issue.key, commentId: comment.id),
                    bodyADFJSON: adfJSON,
                    createdAt: created,
                    receivedAt: Date(),
                    isRead: isHistorical,
                    source: .rest)
                if store.insertIfNew(notification) {
                    if !isHistorical {
                        inserted.append(notification)
                    }
                }
            }
        } catch {
            fetchFailed = true
        }

        // Changelog → Status-/Zuweisungs-Events.
        do {
            let histories = try await client.changelog(issueKey: issue.key)
            for history in histories {
                guard history.author?.accountId != myAccountId else { continue }
                let created = JiraDate.parse(history.created) ?? .distantPast
                let isHistorical = created <= historicalCutoff

                let author = history.author?.displayName ?? "jemand"
                for item in history.items {
                    guard let event = describe(item: item, author: author) else { continue }
                    let notification = JiraNotification(
                        dedupKey: "change:\(issue.key):\(history.id):\(item.field)",
                        issueKey: issue.key,
                        issueSummary: issue.fields.summary,
                        kind: event.kind,
                        title: event.title,
                        bodyPreview: event.body,
                        actorName: author,
                        actorAvatarURLString: history.author?.avatar48,
                        webURLString: appState.issueWebURL(issue.key),
                        createdAt: created,
                        receivedAt: Date(),
                        isRead: isHistorical,
                        source: .rest)
                    if store.insertIfNew(notification) {
                        if !isHistorical {
                            inserted.append(notification)
                        }
                    }
                }
            }
        } catch {
            fetchFailed = true
        }

        if !fetchFailed {
            store.upsertCursor(issueKey: issue.key,
                               lastSeenUpdated: issueUpdated,
                               lastSeenCommentId: newestCommentId)
        }

        return inserted
    }

    private func describe(item: ChangeItem, author: String) -> (kind: NotificationKind, title: String, body: String)? {
        switch item.field {
        case "status":
            return (.statusChange,
                    "\(author) änderte den Status",
                    "\(item.fromString ?? "?") → \(item.toString ?? "?")")
        case "assignee":
            let assignee = item.toString ?? ""
            let body = assignee.isEmpty ? "Zuweisung aufgehoben" : "Zugewiesen an \(assignee)"
            return (.assignment, "\(author) änderte die Zuweisung", body)
        default:
            return nil // andere Feldänderungen ignorieren wir in M1
        }
    }
}
