import Foundation
import Observation

/// Pollt Jira in festem Intervall, leitet aus Issues/Kommentaren/Changelog
/// Notification-Events ab und persistiert neue Einträge im `NotificationStore`.
/// In M1 ohne Push (das ist M2); das Menüleisten-Badge wird über den Store
/// (`unreadDidChange`) aktualisiert.
@MainActor
@Observable
final class SyncEngine {
    private(set) var isSyncing = false
    private(set) var lastError: String?
    private(set) var lastSyncedAt: Date?

    private let appState: AppState
    private let store: NotificationStore
    private let push: PushPresenter
    private var timer: Timer?

    private static let interval: TimeInterval = 90
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
    }

    /// Beim Trennen zurücksetzen, damit ein neuer Account wieder still startet.
    func resetBaseline() {
        didEstablishBaseline = false
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.syncNow() }
        }
        self.timer = timer
        Task { await syncNow() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
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
            store.save()
            lastError = nil
            lastSyncedAt = Date()

            // Erst-Sync still einlesen; ab dann neue Einträge pushen.
            if didEstablishBaseline {
                push.presentBatch(fresh)
            } else {
                // Historische Einträge direkt als gelesen markieren – kein Badge-Flood.
                fresh.forEach { $0.isRead = true }
                store.save()
                didEstablishBaseline = true
            }
        } catch {
            lastError = (error as? JiraError)?.userMessage ?? error.localizedDescription
        }
    }

    // MARK: - Per-issue processing

    /// Verarbeitet ein Issue und gibt die neu eingefügten Notifications zurück.
    private func process(issue: IssueDTO, client: JiraClient) async -> [JiraNotification] {
        var inserted: [JiraNotification] = []
        let issueUpdated = JiraDate.parse(issue.fields.updated) ?? .distantPast
        let cursor = store.cursor(for: issue.key)

        // Unverändert seit letztem Sync? Dann sparen wir uns die Detail-Requests.
        if let cursor, issueUpdated <= cursor.lastSeenUpdated { return inserted }

        let myAccountId = appState.accountId
        var newestCommentId: String?

        // Kommentare → eigene Timeline-Events (Dedup über Kommentar-ID).
        if let comments = try? await client.comments(issueKey: issue.key) {
            newestCommentId = comments.first?.id
            for comment in comments {
                guard comment.author?.accountId != myAccountId else { continue } // eigene überspringen
                let created = JiraDate.parse(comment.created) ?? .distantPast
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
                    isRead: false,
                    source: .rest)
                if store.insertIfNew(notification) { inserted.append(notification) }
            }
        }

        // Changelog → Status-/Zuweisungs-Events.
        if let histories = try? await client.changelog(issueKey: issue.key) {
            for history in histories {
                guard history.author?.accountId != myAccountId else { continue }
                let created = JiraDate.parse(history.created) ?? .distantPast
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
                        isRead: false,
                        source: .rest)
                    if store.insertIfNew(notification) { inserted.append(notification) }
                }
            }
        }

        store.upsertCursor(issueKey: issue.key,
                           lastSeenUpdated: issueUpdated,
                           lastSeenCommentId: newestCommentId)
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
