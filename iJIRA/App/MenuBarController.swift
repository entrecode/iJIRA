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

    /// Menüleisten-Icon im Stil des App-Icons: drei gestaffelte Winkel
    /// („»" nach oben-rechts). Als Template gezeichnet, damit die Menüleiste
    /// es systemkonform schwarz/weiß tinten kann.
    static let statusBarIcon: NSImage = {
        // Drei „⌐"-Winkel in 100er-Koordinaten (y nach unten): Ecke oben-rechts,
        // horizontaler Arm nach links, vertikaler Arm nach unten.
        let brackets: [(corner: CGPoint, h: CGFloat, v: CGFloat)] = [
            (CGPoint(x: 70, y: 26), 44, 44),
            (CGPoint(x: 58, y: 40), 39, 40),
            (CGPoint(x: 46, y: 54), 34, 32),
        ]
        let stroke: CGFloat = 9  // Strichbreite im 100er-Space

        // Gesamt-Bounds inkl. halber Strichbreite bestimmen …
        var minX = CGFloat.greatestFiniteMagnitude, minY = minX
        var maxX = -minX, maxY = -minX
        for b in brackets {
            minX = min(minX, b.corner.x - b.h); maxX = max(maxX, b.corner.x)
            minY = min(minY, b.corner.y);       maxY = max(maxY, b.corner.y + b.v)
        }
        let pad = stroke / 2
        minX -= pad; minY -= pad; maxX += pad; maxY += pad
        let boxW = maxX - minX, boxH = maxY - minY

        let image = NSImage(size: NSSize(width: 18, height: 16), flipped: false) { rect in
            // Seitenverhältnis wahren, zentriert einpassen; y spiegeln
            // (100er-Space ist top-down, NSImage bottom-up).
            let scale = min(rect.width / boxW, rect.height / boxH)
            let offX = rect.minX + (rect.width - boxW * scale) / 2
            let offY = rect.minY + (rect.height - boxH * scale) / 2
            func tx(_ x: CGFloat) -> CGFloat { offX + (x - minX) * scale }
            func ty(_ y: CGFloat) -> CGFloat { offY + (maxY - y) * scale }

            let path = NSBezierPath()
            for b in brackets {
                path.move(to: NSPoint(x: tx(b.corner.x - b.h), y: ty(b.corner.y)))
                path.line(to: NSPoint(x: tx(b.corner.x),       y: ty(b.corner.y)))
                path.line(to: NSPoint(x: tx(b.corner.x),       y: ty(b.corner.y + b.v)))
            }
            path.lineWidth = stroke * scale
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()

    /// Aktualisiert Icon + Zahl anhand der ungelesen-Anzahl.
    func updateBadge(unread: Int) {
        guard let button = statusItem.button else { return }
        button.image = Self.statusBarIcon
        button.image?.accessibilityDescription = unread > 0
            ? "iJIRA – \(unread) neue Benachrichtigungen"
            : "iJIRA"
        button.title = unread > 0 ? " \(unread)" : ""
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = Self.statusBarIcon
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
