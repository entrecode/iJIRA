import Foundation
import Observation

/// Angefangene, noch nicht gesendete Kommentare pro Issue — überleben das
/// Verlassen des Issues (Zurück, Link, Tab-Wechsel, Fenster schließen) und
/// den Neuaufbau des Popovers für die laufende Session. Hauptfenster,
/// Einzelfenster und Popover teilen sich den Entwurf eines Issues. Bewusst
/// nur im Speicher.
@MainActor
@Observable
final class CommentDrafts {
    static let shared = CommentDrafts()

    private var drafts: [String: String] = [:]

    private init() {}

    subscript(issueKey: String) -> String {
        get { drafts[issueKey] ?? "" }
        set { drafts[issueKey] = newValue.isEmpty ? nil : newValue }
    }
}
