import Foundation
import Observation

/// Zustand des Hauptfensters: aktiver Tab (Board ⇄ Issue ⇄ Review & Plan),
/// aktuelles Issue, der Navigationsverlauf (Zurück/Vorwärts) und ein kleiner
/// LRU-Cache der Issue-Modelle, damit das Zurückwechseln zu kürzlich offenen
/// Issues sofort rendert (Thumbnails, Kommentare etc. bleiben im Speicher).
@MainActor
@Observable
final class MainWindowModel {
    enum Tab: String {
        case board
        case issue
        case review
    }

    /// Ein Ziel im Verlauf. `issue(nil)` ist der leere Issue-Tab.
    enum Destination: Hashable {
        case board
        case review
        case issue(String?)
    }

    /// Nur über `navigate(to:)`/`goBack()`/`goForward()` setzen — sonst
    /// fehlt der Schritt im Verlauf.
    private(set) var tab: Tab {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: Self.tabKey) }
    }
    private(set) var currentIssueKey: String?

    /// Verlauf, jüngster Eintrag jeweils am Ende. Nur im Speicher.
    private(set) var backStack: [Destination] = []
    private(set) var forwardStack: [Destination] = []

    /// „Neues Issue"-Dialog (Sheet).
    var showCreateSheet = false

    private let appState: AppState
    private let directory: UserDirectory
    /// Reine Caches, bewusst nicht beobachtet: `issueModel(for:)` wird aus
    /// dem View-Body aufgerufen und schreibt hier — beobachtet würde jeder
    /// Aufruf ein neues Rendern auslösen (Endlosschleife, App hängt).
    @ObservationIgnored private var issueModels: [String: IssueDetailModel] = [:]
    @ObservationIgnored private var recentKeys: [String] = []

    private static let tabKey = "mainTab"
    private static let lastIssueKey = "lastIssueKey"
    private static let modelLimit = 8
    private static let historyLimit = 50

    init(appState: AppState, directory: UserDirectory) {
        self.appState = appState
        self.directory = directory
        tab = Tab(rawValue: UserDefaults.standard.string(forKey: Self.tabKey) ?? "") ?? .board
        currentIssueKey = UserDefaults.standard.string(forKey: Self.lastIssueKey)
    }

    // MARK: - Navigation

    var current: Destination {
        switch tab {
        case .board: return .board
        case .review: return .review
        case .issue: return .issue(currentIssueKey)
        }
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// Neuer Schritt: das aktuelle Ziel wandert in den Verlauf, „Vorwärts"
    /// verfällt (wie im Browser). Dasselbe Ziel erneut → kein Eintrag.
    func navigate(to destination: Destination) {
        let from = current
        guard destination != from else { return }
        backStack.append(from)
        forwardStack.removeAll()
        apply(destination)
        normalizeBackStack()
    }

    /// Board und Review & Plan stehen höchstens einmal im Verlauf — an der
    /// zuletzt besuchten Stelle; ist eins davon gerade offen, gar nicht.
    /// Issues dürfen mehrfach vorkommen (A → B → A ist ein echter Weg).
    private func normalizeBackStack() {
        var seen: Set<Destination> = [current]
        var newestFirst: [Destination] = []
        for destination in backStack.reversed() {
            if destination == .board || destination == .review {
                guard seen.insert(destination).inserted else { continue }
            }
            // Durchs Entfernen direkt benachbarte Doppel zusammenfassen.
            if newestFirst.last == destination { continue }
            newestFirst.append(destination)
        }
        while newestFirst.first == current {
            newestFirst.removeFirst()
        }
        backStack = Array(newestFirst.prefix(Self.historyLimit).reversed())
    }

    /// Den Tab des Umschalters zeigen — beim Issue-Tab das zuletzt offene Issue.
    func navigate(toTab tab: Tab) {
        switch tab {
        case .board: navigate(to: .board)
        case .review: navigate(to: .review)
        case .issue: navigate(to: .issue(currentIssueKey))
        }
    }

    func openIssue(_ rawKey: String) {
        let key = rawKey.uppercased()
        navigate(to: .issue(key))
        Log.app.info("Hauptfenster: Issue \(key, privacy: .public)")
    }

    /// `steps` Schritte zurück (Verlaufsmenü: direkt mehrere auf einmal).
    func goBack(steps: Int = 1) {
        for _ in 0..<steps {
            guard let target = backStack.popLast() else { return }
            forwardStack.append(current)
            apply(target)
        }
    }

    func goForward() {
        guard let target = forwardStack.popLast() else { return }
        backStack.append(current)
        apply(target)
    }

    /// Ziel `steps` Schritte zurück, ohne zu navigieren (für ⌘-Klick: das
    /// Issue im Einzelfenster öffnen, Hauptfenster bleibt stehen).
    func backTarget(steps: Int = 1) -> Destination? {
        guard steps >= 1, steps <= backStack.count else { return nil }
        return backStack[backStack.count - steps]
    }

    /// Anzeigename eines Ziels — für Tooltip und Verlaufsmenü.
    func title(for destination: Destination) -> String {
        switch destination {
        case .board: return "Board"
        case .review: return "Review & Plan"
        case .issue(nil): return "Issue"
        case .issue(let key?):
            if let summary = issueModels[key]?.detail?.fields.summary {
                return "\(key) · \(summary)"
            }
            return key
        }
    }

    private func apply(_ destination: Destination) {
        switch destination {
        case .board:
            tab = .board
        case .review:
            tab = .review
        case .issue(let key):
            currentIssueKey = key
            if let key {
                UserDefaults.standard.set(key, forKey: Self.lastIssueKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.lastIssueKey)
            }
            tab = .issue
        }
    }

    // MARK: - Issue-Modelle

    func issueModel(for key: String) -> IssueDetailModel {
        recentKeys.removeAll { $0 == key }
        recentKeys.append(key)
        if let model = issueModels[key] { return model }

        let model = IssueDetailModel(issueKey: key, appState: appState, directory: directory)
        issueModels[key] = model
        while recentKeys.count > Self.modelLimit {
            let oldest = recentKeys.removeFirst()
            issueModels[oldest] = nil
        }
        return model
    }
}
