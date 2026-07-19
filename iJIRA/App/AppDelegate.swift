import AppKit
import UserNotifications

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appState = AppState()
    private let store = NotificationStore()
    private lazy var pushPresenter = PushPresenter(store: store)
    private var syncEngine: SyncEngine?
    private var menuBarController: MenuBarController?

    /// Manueller App-Bootstrap (statt @NSApplicationMain), damit die AppKit-Hülle
    /// volle Kontrolle über Lifecycle und Aktivierungspolitik behält.
    /// .accessory = Menüleisten-Agent ohne Dock-Icon (zusätzlich via LSUIElement).
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Vollständige Menüleiste — sichtbar, sobald die App per
        // ActivationPolicy regulär wird; die Edit-Shortcuts greifen auch im
        // Agent-Modus über die Responder-Chain.
        MainMenu.install(target: self)

        // Notification Center: Delegate, Actions, Berechtigung.
        UNUserNotificationCenter.current().delegate = pushPresenter
        pushPresenter.registerCategories()
        pushPresenter.requestAuthorization()

        // Fenster-Infrastruktur: Issue-Einzelfenster, Hauptfenster, Settings.
        IssueWindowManager.configure(appState: appState)
        MainWindowController.configure(appState: appState,
                                       directory: IssueWindowManager.shared.userDirectory)
        SettingsWindowController.configure(appState: appState)

        // Sync-Engine + AppKit-Hülle verdrahten.
        let engine = SyncEngine(appState: appState, store: store, push: pushPresenter)
        syncEngine = engine
        let controller = MenuBarController(appState: appState, store: store, syncEngine: engine)
        menuBarController = controller

        // Badge folgt jeder Store-Mutation (Sync-Insert wie auch „gelesen").
        store.unreadDidChange = { [weak controller] count in
            controller?.updateBadge(unread: count)
        }
        
        // Notifications bei Gelesen-Markierung aus dem Notification Center entfernen.
        store.onNotificationsRead = { keys in
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: keys)
        }

        // Tap auf die Sammel-Notification öffnet das Popover.
        pushPresenter.openPopover = { [weak controller] in
            controller?.showPopover()
        }

        // Hauptfenster öffnet → Popover schließen (kein Kampf um Key-Status).
        MainWindowController.shared.onWillShow = { [weak controller] in
            controller?.closePopover()
        }

        // Sync an den Verbindungsstatus koppeln.
        appState.onConnectionChanged = { [weak engine] connection in
            if case .connected = connection {
                engine?.start()
                // Personen-Verzeichnis für Assignee-/Mention-Vorschläge vorladen.
                IssueWindowManager.shared.preloadDirectory()
            } else {
                engine?.stop()
                // Explizite Trennung: Baseline zurücksetzen, damit ein neuer
                // Account wieder still (ohne Push-Flut) startet.
                if case .disconnected = connection {
                    engine?.resetBaseline()
                }
            }
        }

        // Vorhandene Zugangsdaten (Keychain + UserDefaults) wiederherstellen und
        // — falls vollständig — automatisch verbinden (löst dann start() aus).
        Task { await appState.restore() }

        // Standard: still in der Menüleiste starten (Autostart!). Auf Wunsch
        // direkt mit Hauptfenster.
        if UserDefaults.standard.bool(forKey: "showWindowOnLaunch") {
            MainWindowController.shared.show()
        }
    }

    /// App „erneut geöffnet" (Dock-Klick, Doppelklick im Finder, Spotlight):
    /// das ist der Moment für das Hauptfenster.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        MainWindowController.shared.show()
        return false
    }

    // MARK: - Menü-Actions

    @objc func openSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    @objc func showMainWindow(_ sender: Any?) {
        MainWindowController.shared.show()
    }

    @objc func showBoardTab(_ sender: Any?) {
        MainWindowController.shared.showBoard()
    }

    @objc func showIssueTab(_ sender: Any?) {
        MainWindowController.shared.showIssueTab()
    }

    @objc func refreshCurrentTab(_ sender: Any?) {
        MainWindowController.shared.refreshCurrentTab()
    }

    /// Deep-Links: ijira://issue/ONE-1234 öffnet das Issue-Fenster.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let key = JiraKeyParser.key(from: url.absoluteString) {
                IssueWindowManager.shared.open(issueKey: key)
            }
        }
    }

}
