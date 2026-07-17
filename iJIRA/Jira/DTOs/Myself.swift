import Foundation

/// Antwort von `GET /rest/api/3/myself` — der aktuell authentifizierte Nutzer.
struct Myself: Decodable, Sendable {
    let accountId: String
    let displayName: String
    let emailAddress: String?
    let avatarUrls: [String: String]?

    var avatar48: String? { avatarUrls?["48x48"] }
}
