import AppKit
import SwiftUI

/// Kopieren in die Zwischenablage. Zentral, weil es an mehreren Stellen
/// gebraucht wird: Key-Chip, Link-Button und „Link kopieren" (⌘⇧C) im Menü.
extension NSPasteboard {
    /// Ersetzt den Inhalt durch `string` — Kopieren ersetzt immer alles.
    static func copy(_ string: String) {
        general.clearContents()
        general.setString(string, forType: .string)
    }
}

/// Kopiert `text` und hält `feedback` 1,2 s auf `true` — für das kurze
/// Häkchen an Copy-Buttons statt eines stillen Klicks.
@MainActor
func copyWithFeedback(_ text: String, into feedback: Binding<Bool>) {
    NSPasteboard.copy(text)
    feedback.wrappedValue = true
    Task {
        try? await Task.sleep(for: .seconds(1.2))
        feedback.wrappedValue = false
    }
}
