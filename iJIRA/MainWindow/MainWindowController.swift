import AppKit
import SwiftUI

/// Besitzt das eine Hauptfenster (Board ⇄ Issue). Das Fenster wird beim
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
        ActivationPolicy.windowBecameVisible()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showBoard() {
        show()
        model.tab = .board
    }

    func showIssueTab() {
        show()
        model.tab = .issue
    }

    func showReviewTab() {
        show()
        model.tab = .review
    }

    func showIssue(key: String) {
        show()
        model.openIssue(key)
    }

    func showCreateIssue() {
        show()
        model.showCreateSheet = true
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
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // Verzögert prüfen — beim Delegate-Aufruf ist das Fenster noch sichtbar.
        DispatchQueue.main.async { ActivationPolicy.windowClosed() }
    }
}
