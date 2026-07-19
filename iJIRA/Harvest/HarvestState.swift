import Foundation
import Observation

/// Konfiguration + Zustand der Harvest-Verbindung. Token liegt in der
/// Keychain, Rest in UserDefaults. Projekt und Aufgabe („Billable Type")
/// gelten fix für alle Issues (bewusst simpel, wie gewünscht).
@MainActor
@Observable
final class HarvestState {
    private(set) static var shared: HarvestState!

    static func configure() {
        shared = HarvestState()
    }

    // Eingabefelder (an die Settings-UI gebunden)
    var accessToken: String
    var accountId: String

    private(set) var verifiedUserName: String?
    private(set) var verifyError: String?
    private(set) var isVerifying = false
    private(set) var userId: Int?
    private(set) var assignments: [HarvestProjectAssignment] = []

    var projectId: Int? {
        didSet {
            persistInt(projectId, key: Self.projectKey)
            // Task zurücksetzen, wenn er nicht zum neuen Projekt gehört.
            if let taskId, !availableTasks.contains(where: { $0.task.id == taskId }) {
                self.taskId = nil
            }
        }
    }
    var taskId: Int? {
        didSet { persistInt(taskId, key: Self.taskKey) }
    }

    private let keychain = KeychainStore(service: "de.entrecode.iJIRA.harvest")
    private let defaults = UserDefaults.standard

    private static let tokenAccount = "token"
    private static let accountKey = "harvestAccountId"
    private static let userIdKey = "harvestUserId"
    private static let userNameKey = "harvestUserName"
    private static let projectKey = "harvestProjectId"
    private static let taskKey = "harvestTaskId"

    private init() {
        accessToken = keychain.get(account: Self.tokenAccount) ?? ""
        accountId = defaults.string(forKey: Self.accountKey) ?? ""
        verifiedUserName = defaults.string(forKey: Self.userNameKey)
        let storedUser = defaults.integer(forKey: Self.userIdKey)
        userId = storedUser == 0 ? nil : storedUser
        let storedProject = defaults.integer(forKey: Self.projectKey)
        projectId = storedProject == 0 ? nil : storedProject
        let storedTask = defaults.integer(forKey: Self.taskKey)
        taskId = storedTask == 0 ? nil : storedTask
    }

    /// Vollständig konfiguriert → Zeit-Loggen-Button erscheint.
    var isConfigured: Bool {
        !accessToken.isEmpty && !accountId.isEmpty && userId != nil
            && projectId != nil && taskId != nil
    }

    func client() -> HarvestClient? {
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !account.isEmpty else { return nil }
        return HarvestClient(accessToken: token, accountId: account)
    }

    var availableTasks: [HarvestTaskAssignment] {
        assignments.first { $0.project.id == projectId }?.taskAssignments ?? []
    }

    var projectName: String? {
        assignments.first { $0.project.id == projectId }?.project.name
            ?? (projectId != nil ? "Projekt \(projectId!)" : nil)
    }

    var taskName: String? {
        availableTasks.first { $0.task.id == taskId }?.task.name
            ?? (taskId != nil ? "Task \(taskId!)" : nil)
    }

    // MARK: - Aktionen

    /// Verbindungstest: `users/me` + Projekt-Zuweisungen laden; bei Erfolg
    /// Token/IDs persistieren.
    func verify() async {
        guard let client = client() else {
            verifyError = "Token und Account-ID eingeben."
            return
        }
        isVerifying = true
        defer { isVerifying = false }
        do {
            let user = try await client.me()
            userId = user.id
            verifiedUserName = user.displayName
            verifyError = nil
            try? keychain.set(accessToken.trimmingCharacters(in: .whitespacesAndNewlines),
                              account: Self.tokenAccount)
            defaults.set(accountId.trimmingCharacters(in: .whitespacesAndNewlines),
                         forKey: Self.accountKey)
            defaults.set(user.id, forKey: Self.userIdKey)
            defaults.set(user.displayName, forKey: Self.userNameKey)
            assignments = try await client.projectAssignments()
            Log.app.info("Harvest: verbunden als \(user.displayName, privacy: .public), \(self.assignments.count) Projekte")
        } catch {
            verifyError = (error as? HarvestError)?.userMessage ?? error.localizedDescription
            verifiedUserName = nil
            Log.app.error("Harvest-Verbindung fehlgeschlagen: \(self.verifyError ?? "?", privacy: .public)")
        }
    }

    /// Für die Settings-Ansicht: Picker-Daten nachladen, wenn bereits
    /// konfiguriert (Namen statt nackter IDs anzeigen).
    func loadAssignmentsIfNeeded() async {
        guard assignments.isEmpty, let client = client(), userId != nil else { return }
        assignments = (try? await client.projectAssignments()) ?? []
    }

    func disconnect() {
        try? keychain.delete(account: Self.tokenAccount)
        accessToken = ""
        accountId = ""
        verifiedUserName = nil
        verifyError = nil
        userId = nil
        projectId = nil
        taskId = nil
        assignments = []
        defaults.removeObject(forKey: Self.accountKey)
        defaults.removeObject(forKey: Self.userIdKey)
        defaults.removeObject(forKey: Self.userNameKey)
    }

    private func persistInt(_ value: Int?, key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
