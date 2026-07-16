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
        // Hauptmenü installieren, damit Tastatur-Kurzbefehle (⌘C/⌘V/⌘X/⌘A,
        // ⌘Z) in Textfeldern funktionieren. Ohne Edit-Menü verteilt macOS
        // diese Key-Equivalents nicht – bei einem .accessory-Agent fehlt es
        // sonst komplett. Das Menü bleibt unsichtbar (Agent hat keine
        // Menüleiste), die Shortcuts greifen aber über die Responder-Chain.
        installMainMenu()

        // Notification Center: Delegate, Actions, Berechtigung.
        UNUserNotificationCenter.current().delegate = pushPresenter
        pushPresenter.registerCategories()
        pushPresenter.requestAuthorization()

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

        // Sync an den Verbindungsstatus koppeln.
        appState.onConnectionChanged = { [weak engine] connection in
            if case .connected = connection {
                engine?.start()
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
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        // App-Menü (mindestens „Beenden" mit ⌘Q)
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "iJIRA beenden",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu

        // Edit-Menü – liefert die Standard-Key-Equivalents an den First Responder.
        // target = nil ⇒ Aktionen laufen über die Responder-Chain ans Textfeld.
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Bearbeiten")
        editItem.title = "Bearbeiten"
        editMenu.addItem(withTitle: "Widerrufen", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Wiederholen", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Ausschneiden", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Kopieren", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Einsetzen", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Alles auswählen", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }
}
