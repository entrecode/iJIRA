import AppKit
import SwiftUI

/// Besitzt das eine Hauptfenster (Board ⇄ Issue ⇄ Review). Das Fenster wird beim
/// Schließen nur ausgeblendet und lebt weiter — Wieder-Öffnen ist sofort da.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private(set) static var shared: MainWindowController!

    static func configure(appState: AppState, directory: UserDirectory, boardStore: BoardStore) {
        shared = MainWindowController(appState: appState, directory: directory, boardStore: boardStore)
    }

    let model: MainWindowModel
    let boardStore: BoardStore
    let reviewStore: ReviewStore
    private var window: NSWindow?
    private var mouseMonitor: Any?

    /// Vor dem Anzeigen aufgerufen (z. B. Menüleisten-Popover schließen).
    var onWillShow: (() -> Void)?

    private init(appState: AppState, directory: UserDirectory, boardStore: BoardStore) {
        model = MainWindowModel(appState: appState, directory: directory)
        self.boardStore = boardStore
        reviewStore = ReviewStore(appState: appState, boardStore: boardStore)
        super.init()
    }

    func show() {
        onWillShow?()
        if window == nil { window = makeWindow() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showBoard() {
        show()
        model.navigate(toTab: .board)
    }

    func showIssueTab() {
        show()
        model.navigate(toTab: .issue)
    }

    func showReviewTab() {
        show()
        model.navigate(toTab: .review)
    }

    // MARK: - Verlauf

    /// Zurück (Button, Verlaufsmenü, ⌘[, Maustaste). Mit `inNewWindow` und
    /// einem Issue als Ziel öffnet es als Einzelfenster und das Hauptfenster
    /// bleibt stehen — wie ⌘-Klick auf Zurück im Browser. Board und Review
    /// gibt es nur im Hauptfenster, dort wird daraus ein normales Zurück.
    func goBack(steps: Int = 1, inNewWindow: Bool = false) {
        if inNewWindow, case .issue(let key?) = model.backTarget(steps: steps) {
            IssueWindowManager.shared.open(issueKey: key, preferWindow: true)
            return
        }
        model.goBack(steps: steps)
    }

    func goForward() {
        model.goForward()
    }

    /// ⌘[ / ⌘] nur im Hauptfenster — und nicht, solange in einem Editor
    /// Text steht: der Entwurf (Beschreibung, Titel …) wäre sonst weg.
    func canNavigateHistory(forward: Bool) -> Bool {
        guard let window, window.isKeyWindow else { return false }
        if let editor = window.firstResponder as? NSTextView,
           editor.isEditable, !editor.string.isEmpty {
            return false
        }
        return forward ? model.canGoForward : model.canGoBack
    }

    /// Maus-Seitentasten (Taste 4 = zurück, 5 = vorwärts) im Hauptfenster.
    private func installMouseNavigationMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            switch event.buttonNumber {
            case 3:
                self.goBack(inNewWindow: event.modifierFlags.contains(.command))
                return nil
            case 4:
                self.goForward()
                return nil
            default:
                return event
            }
        }
    }

    func showIssue(key: String) {
        show()
        model.openIssue(key)
    }

    func showCreateIssue() {
        show()
        model.showCreateSheet = true
    }

    /// Issue-Key des aktiven Tabs — nil, wenn `candidate` nicht das
    /// Hauptfenster ist oder gerade kein Issue-Tab offen liegt. Für
    /// Menü-Actions aufs vorderste Issue (⌘⇧C).
    func issueKey(for candidate: NSWindow) -> String? {
        guard candidate === window, model.tab == .issue else { return nil }
        return model.currentIssueKey
    }

    /// ⌘R / Toolbar: aktualisiert den Inhalt des aktiven Tabs.
    func refreshCurrentTab() {
        switch model.tab {
        case .issue:
            if let key = model.currentIssueKey {
                Task { await model.issueModel(for: key).refresh() }
            }
        case .board:
            boardStore.kickRefresh()
        case .review:
            reviewStore.kickRefresh()
        }
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: MainWindowView(model: model,
                                                                  boardStore: boardStore,
                                                                  reviewStore: reviewStore))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "iJIRA"
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.isReleasedWhenClosed = false
        window.applyTransparentBackdrop()
        window.setContentSize(NSSize(width: 1080, height: 760))
        window.minSize = NSSize(width: 900, height: 640)
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.delegate = self
        installMouseNavigationMonitor()
        return window
    }
}
