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
    private(set) var myAvatarURLString: String?

    /// Letzter Verbindungsfehler war ein 401/403 — automatische Retries wären
    /// dann sinnlos (und würden Jira mit falschen Credentials hämmern).
    private var lastConnectWasAuthFailure = false

    /// Snapshot des zuletzt erfolgreich verbundenen Clients. Der Sync nutzt
    /// diesen statt der live an die Settings-UI gebundenen Felder — sonst
    /// würde Tippen im Token-Feld sofort die laufenden Requests kaputt machen.
    private var activeClient: JiraClient?

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

    /// Beim Start aufgerufen. Verbindet, sobald Zugangsdaten lesbar sind — und
    /// versucht es periodisch weiter: Beim automatischen Start (Login-Item,
    /// Dark Wake) kann der Keychain-Read transient scheitern (OSStatus -25320
    /// „no UI possible") und das Netzwerk ist oft noch nicht da. Nur bei
    /// tatsächlich abgelehnter Anmeldung (401) wird aufgegeben — dann muss der
    /// User das Token prüfen.
    func restore() async {
        while !isConnected {
            await retryRestoreIfNeeded()
            if isConnected { return }
            if lastConnectWasAuthFailure {
                Log.app.error("Restore aufgegeben: Anmeldung abgelehnt, Token prüfen.")
                return
            }
            try? await Task.sleep(nanoseconds: 30_000_000_000)
        }
    }

    /// Ein einzelner Wiederverbindungs-Versuch (auch beim Öffnen des Popovers
    /// aufgerufen — mit sichtbarer UI darf die Keychain nachfragen).
    func retryRestoreIfNeeded() async {
        guard !isConnected, !isConnecting else { return }
        if apiToken.isEmpty, !email.isEmpty {
            apiToken = keychain.get(account: email) ?? ""
        }
        guard !email.isEmpty, !apiToken.isEmpty else {
            Log.app.info("Restore: keine vollständigen Zugangsdaten (E-Mail: \(!self.email.isEmpty), Token: \(!self.apiToken.isEmpty))")
            return
        }
        await connect()
    }

    /// Verbindungstest gegen `/myself`. Bei Erfolg werden Site/E-Mail in
    /// UserDefaults und das Token in der Keychain persistiert.
    func connect() async {
        guard !isConnecting else { return }
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
            myAvatarURLString = me.avatar48
            activeClient = client
            lastConnectWasAuthFailure = false
            persist(token: token, email: trimmedEmail)
            Log.app.info("Verbunden als \(me.displayName, privacy: .public)")
            setConnection(.connected(displayName: me.displayName,
                                     accountEmail: me.emailAddress ?? trimmedEmail))
        } catch {
            if case JiraError.unauthorized = error {
                lastConnectWasAuthFailure = true
            } else {
                lastConnectWasAuthFailure = false
            }
            let message = (error as? JiraError)?.userMessage ?? error.localizedDescription
            Log.app.error("Verbindung fehlgeschlagen: \(message, privacy: .public)")
            setConnection(.failed(message))
        }
    }

    /// Token aus der Keychain entfernen und Verbindung zurücksetzen.
    func disconnect() {
        try? keychain.delete(account: email)
        accountId = nil
        activeClient = nil
        setConnection(.disconnected)
    }

    // MARK: - Für SyncEngine

    func currentClient() -> JiraClient? {
        guard isConnected else { return nil }
        return activeClient
    }

    /// Basis-URL der Site (für Ticket-Karten-Links u. Ä.).
    var siteBaseURL: URL? {
        currentClient()?.baseURL ?? normalizedBaseURL()
    }

    func issueWebURL(_ key: String, commentId: String? = nil) -> String {
        guard let base = activeClient?.baseURL ?? normalizedBaseURL() else { return "" }
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
