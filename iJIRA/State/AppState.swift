import Foundation
import Observation

/// Zentraler, beobachtbarer App-Zustand. Hält Verbindungsstatus und
/// Zugangsdaten, kapselt Persistenz (UserDefaults + Keychain) und den
/// Verbindungsaufbau gegen Jira.
@MainActor
@Observable
final class AppState {
    enum Connection: Equatable {
        case disconnected
        case connecting
        case connected(displayName: String, accountEmail: String)
        case failed(String)
    }

    private(set) var connection: Connection = .disconnected
    private(set) var accountId: String?

    // Eingabefelder (an die Settings-UI gebunden)
    var siteURLString: String
    var email: String
    var apiToken: String

    /// Wird bei jeder Statusänderung aufgerufen (Sync starten/stoppen).
    var onConnectionChanged: ((Connection) -> Void)?

    private let defaults = UserDefaults.standard
    private let keychain = KeychainStore(service: AppState.keychainService)

    private static let keychainService = "de.entrecode.iJIRA"
    private static let defaultSite = "https://dein-team.atlassian.net"
    private static let siteKey = "siteURL"
    private static let emailKey = "email"

    init() {
        siteURLString = defaults.string(forKey: Self.siteKey) ?? Self.defaultSite
        let storedEmail = defaults.string(forKey: Self.emailKey) ?? ""
        email = storedEmail
        apiToken = storedEmail.isEmpty ? "" : (keychain.get(account: storedEmail) ?? "")
    }

    var isConnected: Bool {
        if case .connected = connection { return true }
        return false
    }

    var isConnecting: Bool { connection == .connecting }

    /// Beim Start aufgerufen: nur verbinden, wenn alle Daten vorhanden sind.
    func restore() async {
        guard !email.isEmpty, !apiToken.isEmpty else { return }
        await connect()
    }

    /// Verbindungstest gegen `/myself`. Bei Erfolg werden Site/E-Mail in
    /// UserDefaults und das Token in der Keychain persistiert.
    func connect() async {
        guard let base = normalizedBaseURL() else {
            setConnection(.failed("Bitte eine gültige Site-URL angeben."))
            return
        }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, !token.isEmpty else {
            setConnection(.failed("E-Mail und API-Token sind erforderlich."))
            return
        }

        setConnection(.connecting)
        let client = JiraClient(baseURL: base, email: trimmedEmail, apiToken: token)
        do {
            let me = try await client.currentUser()
            accountId = me.accountId
            persist(token: token, email: trimmedEmail)
            setConnection(.connected(displayName: me.displayName,
                                     accountEmail: me.emailAddress ?? trimmedEmail))
        } catch {
            setConnection(.failed((error as? JiraError)?.userMessage ?? error.localizedDescription))
        }
    }

    /// Token aus der Keychain entfernen und Verbindung zurücksetzen.
    func disconnect() {
        try? keychain.delete(account: email)
        accountId = nil
        setConnection(.disconnected)
    }

    // MARK: - Für SyncEngine

    func currentClient() -> JiraClient? {
        guard isConnected, let base = normalizedBaseURL() else { return nil }
        return JiraClient(baseURL: base,
                          email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                          apiToken: apiToken.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func issueWebURL(_ key: String, commentId: String? = nil) -> String {
        guard let base = normalizedBaseURL() else { return "" }
        var string = base.absoluteString + "/browse/" + key
        if let commentId { string += "?focusedCommentId=\(commentId)" }
        return string
    }

    // MARK: - Helpers

    private func setConnection(_ value: Connection) {
        connection = value
        onConnectionChanged?(value)
    }

    private func persist(token: String, email: String) {
        defaults.set(siteURLString.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.siteKey)
        defaults.set(email, forKey: Self.emailKey)
        try? keychain.set(token, account: email)
    }

    private func normalizedBaseURL() -> URL? {
        var raw = siteURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if !raw.lowercased().hasPrefix("http") {
            raw = "https://" + raw
        }
        while raw.hasSuffix("/") {
            raw.removeLast()
        }
        return URL(string: raw)
    }
}
