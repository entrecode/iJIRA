import AppKit
import SwiftUI

/// Macht die Fläche dahinter zum Fenster-Anfasser: Klick + Ziehen bewegt das
/// Fenster (wie die Titlebar), Doppelklick zoomt/minimiert gemäß
/// Systemeinstellung. Als `.background(…)` unter einen Header gelegt greifen
/// Controls darüber weiterhin normal — nur „leere" Stellen ziehen.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DragView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                // Systemeinstellung „Beim Doppelklicken auf Titelleiste":
                if UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") == "Minimize" {
                    window.performMiniaturize(nil)
                } else {
                    window.performZoom(nil)
                }
                return
            }
            window.performDrag(with: event)
        }
    }
}
