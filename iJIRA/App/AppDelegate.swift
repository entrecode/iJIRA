import AppKit
import UserNotifications

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let appState = AppState()
    private let store = NotificationStore()
    private lazy var pushPresenter = PushPresenter(store: store)
    private lazy var boardStore = BoardStore(appState: appState)
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

        // Harvest-Zeiterfassung (optional, Settings-Tab).
        HarvestState.configure()

        // Ticket-Erstellung (Kataloge + Vorbelegung).
        CreateIssueService.configure(appState: appState)

        // Fenster-Infrastruktur: Issue-Einzelfenster, Hauptfenster, Settings.
        IssueWindowManager.configure(appState: appState)
        MainWindowController.configure(appState: appState,
                                       directory: IssueWindowManager.shared.userDirectory,
                                       boardStore: boardStore)
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

        // Tap auf die Sammel-Notification öffnet das Popover; Tap auf eine
        // einzelne Notification direkt die zugehörige Konversation.
        pushPresenter.openPopover = { [weak controller] in
            controller?.showPopover()
        }
        pushPresenter.openConversation = { [weak controller] issueKey in
            controller?.showConversation(issueKey: issueKey)
        }

        // Hauptfenster öffnet → Popover schließen (kein Kampf um Key-Status).
        MainWindowController.shared.onWillShow = { [weak controller] in
            controller?.closePopover()
        }

        // Sync an den Verbindungsstatus koppeln.
        appState.onConnectionChanged = { [weak engine, weak self] connection in
            if case .connected = connection {
                engine?.start()
                self?.boardStore.start()
                // Personen-Verzeichnis für Assignee-/Mention-Vorschläge vorladen.
                IssueWindowManager.shared.preloadDirectory()
                // Projekt-/Team-Kataloge für den Neues-Issue-Dialog vorladen.
                Task { await CreateIssueService.shared.preload() }
            } else {
                engine?.stop()
                self?.boardStore.stop()
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

        // Beim Öffnen der App direkt das Board zeigen (abschaltbar in den
        // Einstellungen, z. B. für stillen Autostart).
        UserDefaults.standard.register(defaults: ["showWindowOnLaunch": true])
        if UserDefaults.standard.bool(forKey: "showWindowOnLaunch") {
            MainWindowController.shared.showBoard()
        }
    }

    /// App „erneut geöffnet" (Dock-Klick, Doppelklick im Finder, Spotlight):
    /// das ist der Moment für das Hauptfenster. Nicht aber direkt nach einem
    /// Notification-Tap — der öffnet gezielt das Popover.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        guard !ReopenSuppressor.isSuppressed else { return false }
        MainWindowController.shared.show()
        return false
    }

    // MARK: - Menü-Actions

    @objc func openSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    @objc func newIssue(_ sender: Any?) {
        MainWindowController.shared.showCreateIssue()
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

    @objc func showReviewTab(_ sender: Any?) {
        MainWindowController.shared.showReviewTab()
    }

    @objc func refreshCurrentTab(_ sender: Any?) {
        MainWindowController.shared.refreshCurrentTab()
    }

    /// ⌘⇧C: Web-Link des vordersten Issues in die Zwischenablage.
    @objc func copyIssueLink(_ sender: Any?) {
        guard let key = frontmostIssueKey() else { return }
        let url = appState.issueWebURL(key)
        guard !url.isEmpty else { return }
        NSPasteboard.copy(url)
        Log.app.info("Link kopiert: \(key, privacy: .public)")
    }

    /// Das Issue, auf das sich Menü-Actions beziehen: entweder ein
    /// Issue-Einzelfenster oder der Issue-Tab des Hauptfensters.
    private func frontmostIssueKey() -> String? {
        guard let window = NSApp.keyWindow else { return nil }
        return IssueWindowManager.shared.issueKey(for: window)
            ?? MainWindowController.shared.issueKey(for: window)
    }

    /// Nur „Link kopieren" ist kontextabhängig — die übrigen Menü-Actions des
    /// Delegates stehen immer zur Verfügung.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(copyIssueLink(_:)) else { return true }
        return frontmostIssueKey() != nil
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
