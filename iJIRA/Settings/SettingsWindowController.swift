import AppKit
import SwiftUI

/// Eigenständiges Einstellungs-Fenster (⌘,) — Verbindung, Allgemein,
/// später Harvest.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private(set) static var shared: SettingsWindowController!

    static func configure(appState: AppState) {
        shared = SettingsWindowController(appState: appState)
    }

    private let appState: AppState
    private var window: NSWindow?

    private init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    func show() {
        if window == nil { window = makeWindow() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView(appState: appState))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.title = "Einstellungen"
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        return window
    }
}
