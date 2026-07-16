import AppKit
import SwiftUI

/// Besitzt das `NSStatusItem` (inkl. ungelesen-Badge) und den `NSPopover`,
/// der die SwiftUI-Oberfläche via `NSHostingController` hostet.
@MainActor
final class MenuBarController: NSObject {
    private let appState: AppState
    private let store: NotificationStore
    private let syncEngine: SyncEngine
    private let statusItem: NSStatusItem
    private let popover = NSPopover()

    init(appState: AppState, store: NotificationStore, syncEngine: SyncEngine) {
        self.appState = appState
        self.store = store
        self.syncEngine = syncEngine
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureStatusItem()
        configurePopover()
        updateBadge(unread: store.unreadCount)
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
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 380, height: 520)
        popover.contentViewController = makeContentViewController()
    }

    /// Baut den Popover-Inhalt frisch auf. Wird bei jedem Öffnen neu erzeugt:
    /// Ein langlebiger `NSHostingController` friert über den System-Schlaf ein
    /// (SwiftUI pausiert Render-Pässe für das off-screen View) und zeigt beim
    /// Wieder-Öffnen einen veralteten Stand samt eingefrorener Relativzeiten.
    /// Ein frischer Controller erzwingt einen Render-Pass mit aktueller Uhr und
    /// aktuellem `@Query`.
    private func makeContentViewController() -> NSViewController {
        let root = RootView(appState: appState, store: store, syncEngine: syncEngine)
            .modelContainer(store.container)
        return NSHostingController(rootView: root)
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
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
