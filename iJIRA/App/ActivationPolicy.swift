import AppKit

/// Die App lebt als Menüleisten-Agent (LSUIElement). Sobald „richtige"
/// Fenster sichtbar sind, braucht sie aber Systemmenüleiste + Dock-Icon —
/// deshalb dynamischer Wechsel der Activation-Policy.
@MainActor
enum ActivationPolicy {
    static func windowBecameVisible() {
        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
        Log.app.info("ActivationPolicy → regular")
    }

    /// Nach dem Schließen eines Fensters: sind keine echten Fenster mehr
    /// sichtbar, zurück zum reinen Agenten (kein Dock-Icon).
    /// Aus `windowWillClose` heraus asynchron aufrufen — dort ist das
    /// schließende Fenster noch `isVisible`.
    static func windowClosed() {
        let stillVisible = NSApp.windows.contains { $0.isVisible && isRealWindow($0) }
        if !stillVisible, NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
            Log.app.info("ActivationPolicy → accessory")
        }
    }

    /// „Echt" = Hauptfenster, Einstellungen, Issue-Einzelfenster —
    /// nicht das Popover oder Panels.
    private static func isRealWindow(_ window: NSWindow) -> Bool {
        guard let id = window.identifier?.rawValue else { return false }
        return id == "main" || id == "settings" || id.hasPrefix("issue-")
    }
}
