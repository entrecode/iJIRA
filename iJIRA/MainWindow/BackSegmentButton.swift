import AppKit
import SwiftUI

/// Zurück-Button im Look der Tab-Segmente — dasselbe NSSegmentedControl wie
/// der Umschalter, nur mit einem Segment. Klick: ein Schritt zurück;
/// gedrückt halten: Verlaufsmenü; ⌘-Klick: ein Issue als Ziel öffnet im
/// Einzelfenster.
struct BackSegmentButton: NSViewRepresentable {
    /// Titel der Verlaufseinträge, jüngster zuerst.
    let entries: [String]
    let help: String
    let onBack: (_ steps: Int, _ inNewWindow: Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Zurück")
            ?? NSImage()
        let control = NSSegmentedControl(images: [image],
                                         trackingMode: .momentary,
                                         target: context.coordinator,
                                         action: #selector(Coordinator.clicked(_:)))
        control.setWidth(40, forSegment: 0)
        control.setShowsMenuIndicator(false, forSegment: 0)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.onBack = onBack
        control.isEnabled = !entries.isEmpty
        control.toolTip = help
        control.setToolTip(help, forSegment: 0)

        // Verlaufsmenü erscheint beim Gedrückthalten des Segments.
        guard !entries.isEmpty else {
            control.setMenu(nil, forSegment: 0)
            return
        }
        let menu = NSMenu()
        for (index, title) in entries.prefix(12).enumerated() {
            let item = NSMenuItem(title: title,
                                  action: #selector(Coordinator.menuItemSelected(_:)),
                                  keyEquivalent: "")
            item.target = context.coordinator
            item.tag = index + 1 // Anzahl Schritte zurück
            menu.addItem(item)
        }
        control.setMenu(menu, forSegment: 0)
    }

    @MainActor
    final class Coordinator: NSObject {
        var onBack: ((Int, Bool) -> Void)?

        private var commandPressed: Bool {
            NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        }

        @objc func clicked(_ sender: NSSegmentedControl) {
            onBack?(1, commandPressed)
        }

        @objc func menuItemSelected(_ sender: NSMenuItem) {
            onBack?(sender.tag, commandPressed)
        }
    }
}
