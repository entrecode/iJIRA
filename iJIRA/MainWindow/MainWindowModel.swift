import Foundation
import Observation

/// Zustand des Hauptfensters: aktiver Tab (Board ⇄ Issue), aktuelles Issue
/// und ein kleiner LRU-Cache der Issue-Modelle, damit das Zurückwechseln zu
/// kürzlich offenen Issues sofort rendert (Thumbnails, Kommentare etc.
/// bleiben im Speicher).
@MainActor
@Observable
final class MainWindowModel {
    enum Tab: String {
        case board
        case issue
    }

    var tab: Tab {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: Self.tabKey) }
    }
    private(set) var currentIssueKey: String?

    private let appState: AppState
    private let directory: UserDirectory
    private var issueModels: [String: IssueDetailModel] = [:]
    private var recentKeys: [String] = []

    private static let tabKey = "mainTab"
    private static let lastIssueKey = "lastIssueKey"
    private static let modelLimit = 8

    init(appState: AppState, directory: UserDirectory) {
        self.appState = appState
        self.directory = directory
        tab = Tab(rawValue: UserDefaults.standard.string(forKey: Self.tabKey) ?? "") ?? .board
        currentIssueKey = UserDefaults.standard.string(forKey: Self.lastIssueKey)
    }

    func openIssue(_ rawKey: String) {
        let key = rawKey.uppercased()
        currentIssueKey = key
        UserDefaults.standard.set(key, forKey: Self.lastIssueKey)
        tab = .issue
        Log.app.info("Hauptfenster: Issue \(key, privacy: .public)")
    }

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
