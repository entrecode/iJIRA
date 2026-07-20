import AppKit
import SwiftUI

/// Navigations-Wünsche ans Popover (z. B. „öffne Konversation X" nach einem
/// Notification-Tap). Beobachtbar, damit die RootView auch bei bereits
/// offenem Popover reagiert.
@MainActor
@Observable
final class PopoverNavigation {
    var pendingIssueKey: String?
}

/// Unterdrückt das Reopen-Handling (Hauptfenster öffnen) kurzzeitig —
/// die App-Aktivierung durch einen Notification-Tap soll NICHT zusätzlich
/// das Hauptfenster hochziehen.
enum ReopenSuppressor {
    nonisolated(unsafe) private static var until = Date.distantPast

    static func suppress(for seconds: TimeInterval) {
        until = Date().addingTimeInterval(seconds)
    }

    static var isSuppressed: Bool {
        Date() < until
    }
}

/// Besitzt das `NSStatusItem` (inkl. ungelesen-Badge) und den `NSPopover`,
/// der die SwiftUI-Oberfläche via `NSHostingController` hostet.
@MainActor
final class MenuBarController: NSObject {
    private(set) static weak var shared: MenuBarController?

    private let appState: AppState
    private let store: NotificationStore
    private let syncEngine: SyncEngine
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let navigation = PopoverNavigation()
    private var resignActiveObserver: NSObjectProtocol?
    private var spaceKeyMonitor: Any?

    init(appState: AppState, store: NotificationStore, syncEngine: SyncEngine) {
        self.appState = appState
        self.store = store
        self.syncEngine = syncEngine
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureStatusItem()
        configurePopover()
        updateBadge(unread: store.unreadCount)
        MenuBarController.shared = self
    }

    /// Aktualisiert Icon + Zahl anhand der ungelesen-Anzahl.
    func updateBadge(unread: Int) {
        guard let button = statusItem.button else { return }
        if unread > 0 {
            button.image = NSImage(systemSymbolName: "bell.badge.fill",
                                   accessibilityDescription: "iJIRA – \(unread) neue Benachrichtigungen")
            button.title = " \(unread)"
        } else {
            button.image = NSImage(systemSymbolName: "bell", accessibilityDescription: "iJIRA")
            button.title = ""
        }
        button.image?.isTemplate = true
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "bell", accessibilityDescription: "iJIRA")
        button.image?.isTemplate = true
        button.target = self
        button.action = #selector(togglePopover(_:))
        // Nie Tastaturfokus auf den Status-Button: sonst kann die Leertaste
        // beim Tippen im Popover den Button „drücken" und es damit schließen.
        button.refusesFirstResponder = true
    }

    private func configurePopover() {
        // Bewusst NICHT .transient: das transiente Verhalten schließt das
        // Popover bei jeder „Interaktion außerhalb" — darunter fiel auch die
        // Leertaste beim Kommentar-Tippen (verlorene Entwürfe). Stattdessen
        // schließen wir selbst: bei App-Deaktivierung (Klick woanders hin),
        // Esc (RootView.onExitCommand) und erneutem Klick aufs Statusicon.
        popover.behavior = .applicationDefined
        popover.contentSize = NSSize(width: 380, height: 520)
        popover.contentViewController = makeContentViewController()

        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                self?.closePopover()
            }
        }

        // Die Leertaste erreicht das Popover-Textfeld nicht zuverlässig: das
        // System (Tastatursteuerung/Menüleisten-Tracking) „drückt" damit den
        // noch fokussierten Status-Button — Space kam nie im Editor an.
        // Der lokale Monitor sieht jedes Key-Event dieses Prozesses zuerst und
        // steckt Space bei offenem Popover direkt in dessen First Responder.
        spaceKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.interceptSpaceIfNeeded(event)
        }
    }

    /// Leertaste bei offenem Popover selbst zustellen (siehe configurePopover).
    private func interceptSpaceIfNeeded(_ event: NSEvent) -> NSEvent? {
        guard popover.isShown,
              event.keyCode == 49, // Space
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let popoverWindow = popover.contentViewController?.view.window
        else { return event }

        // Nur Events abfangen, die fürs Popover bzw. den Status-Button gedacht
        // sind — Tippen in anderen Fenstern bleibt unberührt.
        let statusWindow = statusItem.button?.window
        guard event.window == nil || event.window == popoverWindow || event.window == statusWindow
        else { return event }

        guard let textView = popoverWindow.firstResponder as? NSTextView,
              textView.isEditable else { return event }
        textView.insertText(" ", replacementRange: textView.selectedRange())
        return nil // verschluckt — erreicht weder Button noch Menü-Tracking
    }

    /// Baut den Popover-Inhalt frisch auf. Wird bei jedem Öffnen neu erzeugt:
    /// Ein langlebiger `NSHostingController` friert über den System-Schlaf ein
    /// (SwiftUI pausiert Render-Pässe für das off-screen View) und zeigt beim
    /// Wieder-Öffnen einen veralteten Stand samt eingefrorener Relativzeiten.
    /// Ein frischer Controller erzwingt einen Render-Pass mit aktueller Uhr und
    /// aktuellem `@Query`.
    private func makeContentViewController() -> NSViewController {
        let root = RootView(appState: appState, store: store, syncEngine: syncEngine,
                            navigation: navigation)
            .modelContainer(store.container)
        return NSHostingController(rootView: root)
    }

    /// Öffnet das Popover direkt mit der Konversation eines Issues
    /// (Notification-Tap).
    func showConversation(issueKey: String) {
        navigation.pendingIssueKey = issueKey
        if !popover.isShown {
            openPopover()
        }
    }

    func closePopover() {
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            // Nur echte Mausklicks schließen — ein per Tastatur „gedrückter"
            // Status-Button (Space bei Tastatursteuerung) darf das Popover
            // nicht zuklappen.
            let mouseTypes: Set<NSEvent.EventType> = [
                .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                .otherMouseDown, .otherMouseUp,
            ]
            guard let event = NSApp.currentEvent, mouseTypes.contains(event.type) else { return }
            popover.performClose(sender)
        } else {
            openPopover()
        }
    }

    /// Öffnet das Popover programmatisch (z. B. Tap auf die Sammel-Notification).
    func showPopover() {
        guard !popover.isShown else { return }
        openPopover()
    }

    private func openPopover() {
        guard let button = statusItem.button else { return }
        // Inhalt frisch aufbauen, damit nichts von einem früheren (evtl. über
        // den Schlaf eingefrorenen) Zustand hängen bleibt.
        popover.contentViewController = makeContentViewController()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        // Beim Öffnen frisch synchronisieren (snappy UX). Falls die Verbindung
        // nie zustande kam (Keychain-Read ohne UI gescheitert), jetzt — mit
        // sichtbarer UI — erneut versuchen.
        Task {
            await appState.retryRestoreIfNeeded()
            await syncEngine.syncNow()
        }
    }
}
