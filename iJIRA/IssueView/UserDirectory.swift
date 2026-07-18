import Foundation
import Observation

/// Vorgeladenes Personen-Verzeichnis der Site. Das Team ist klein (20–30
/// Personen), deshalb einmal laden und alle Vorschläge (Assignee, Mentions)
/// lokal filtern — keine Server-Roundtrips beim Tippen.
@MainActor
@Observable
final class UserDirectory {
    private(set) var users: [UserDTO] = []
    private var loaded = false

    func preload(client: JiraClient) async {
        guard !loaded else { return }
        do {
            let all = try await client.allUsers()
            users = all
                .filter { ($0.accountType ?? "atlassian") == "atlassian" && ($0.active ?? true) }
                .sorted { ($0.displayName ?? "") .localizedCaseInsensitiveCompare($1.displayName ?? "") == .orderedAscending }
            loaded = true
            Log.app.info("UserDirectory: \(self.users.count) Personen vorgeladen")
        } catch {
            Log.app.error("UserDirectory: Vorladen fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Lokale Tippsuche (Präfix gewinnt vor Substring).
    func matching(_ query: String) -> [UserDTO] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return users }
        let prefix = users.filter { ($0.displayName ?? "").lowercased().hasPrefix(q) }
        let contains = users.filter {
            let name = ($0.displayName ?? "").lowercased()
            return !name.hasPrefix(q) && name.contains(q)
        }
        return prefix + contains
    }
}
