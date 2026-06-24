import Foundation

/// Antwort von `GET /rest/api/3/myself` — der aktuell authentifizierte Nutzer.
struct Myself: Decodable, Sendable {
    let accountId: String
    let displayName: String
    let emailAddress: String?
}
