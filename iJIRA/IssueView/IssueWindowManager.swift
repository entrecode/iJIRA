import AppKit
import SwiftUI

/// Öffnet und verwaltet Issue-Detail-Fenster — genau ein Fenster pro Issue-Key;
/// erneutes Öffnen holt das bestehende Fenster nach vorn.
@MainActor
final class IssueWindowManager: NSObject, NSWindowDelegate {
    private(set) static var shared: IssueWindowManager!

    static func configure(appState: AppState) {
        shared = IssueWindowManager(appState: appState)
    }

    let appState: AppState
    let userDirectory = UserDirectory()

    private var windows: [String: NSWindow] = [:]
    private var cascadePoint = NSPoint.zero

    private init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    /// Personen-Verzeichnis vorladen (nach dem Connect aufgerufen).
    func preloadDirectory() {
        guard let client = appState.currentClient() else { return }
        Task { await userDirectory.preload(client: client) }
    }

    func open(issueKey rawKey: String) {
        let key = rawKey.uppercased()
        Log.app.info("Issue-Fenster öffnen: \(key, privacy: .public)")
        if let window = windows[key] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let model = IssueDetailModel(issueKey: key, appState: appState, directory: userDirectory)
        let root = IssueDetailView(model: model)
        let hosting = NSHostingController(rootView: root)

        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = key
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 720, height: 780))
        window.minSize = NSSize(width: 560, height: 480)
        window.center()
        cascadePoint = window.cascadeTopLeft(from: cascadePoint)
        window.delegate = self
        windows[key] = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value != window }
    }
}

// MARK: - Key-Erkennung

/// Erkennt Jira-Keys in Rohtext oder Browse-/Deep-Links —
/// "ONE-9191", "https://team.atlassian.net/browse/ONE-9191?…", ….
enum JiraKeyParser {
    private static let keyPattern = try! NSRegularExpression(pattern: "([A-Za-z][A-Za-z0-9_]+-[0-9]+)")

    /// Key aus beliebiger Eingabe (Key, URL, Text mit Key) — nil, wenn keiner enthalten ist.
    static func key(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = keyPattern.firstMatch(in: trimmed, range: range),
              let swiftRange = Range(match.range(at: 1), in: trimmed) else { return nil }
        return String(trimmed[swiftRange]).uppercased()
    }

    /// Ist die Eingabe *direkt* ein Key oder ein Browse-Link (nicht bloß Text,
    /// der irgendwo einen Key enthält)?
    static func directKey(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true {
            guard url.path.contains("/browse/") else { return nil }
            return key(from: url.lastPathComponent)
        }
        guard let found = key(from: trimmed), found.count == trimmed.count else { return nil }
        return found
    }
}
