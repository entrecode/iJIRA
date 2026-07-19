import Foundation
import Observation

/// Alles rund ums Anlegen neuer Tickets: Projekt-/Typ-/Team-/Komponenten-
/// Kataloge (vorgeladen bzw. gecacht) und die Vorbelegung — Werte kommen vom
/// zuletzt ANGELEGTEN Ticket, sonst vom zuletzt ANGESEHENEN.
@MainActor
@Observable
final class CreateIssueService {
    private(set) static var shared: CreateIssueService!

    static func configure(appState: AppState) {
        shared = CreateIssueService(appState: appState)
    }

    struct TeamOption: Identifiable, Hashable, Codable {
        let id: String
        let name: String
    }

    /// Merker für die Vorbelegung des Dialogs.
    struct Defaults: Codable {
        var projectKey: String?
        var issueTypeId: String?
        var teamId: String?
        var teamName: String?
        var componentIds: [String] = []
    }

    private(set) var projects: [ProjectSummaryDTO] = []
    private(set) var teams: [TeamOption] = []
    private(set) var teamFieldId: String?
    private(set) var teamFieldName: String?

    private(set) var lastCreated: Defaults?
    private(set) var lastViewed: Defaults?

    /// Startwerte für den Dialog (Anforderung: zuletzt angelegt > zuletzt angesehen).
    var startDefaults: Defaults { lastCreated ?? lastViewed ?? Defaults() }

    private let appState: AppState
    private var issueTypesCache: [String: [CreateMetaIssueType]] = [:]
    private var componentsCache: [String: [ProjectComponentDTO]] = [:]

    private static let lastCreatedKey = "createDefaults.lastCreated"
    private static let lastViewedKey = "createDefaults.lastViewed"

    private init(appState: AppState) {
        self.appState = appState
        lastCreated = Self.loadDefaults(key: Self.lastCreatedKey)
        lastViewed = Self.loadDefaults(key: Self.lastViewedKey)
    }

    // MARK: - Kataloge

    /// Nach dem Connect: Projekte, Team-Feld und Teams vorladen (snappy Dialog).
    func preload() async {
        guard let client = appState.currentClient() else { return }
        if projects.isEmpty {
            projects = (try? await client.visibleProjects()) ?? []
        }
        if teamFieldId == nil {
            let fields = (try? await client.allFields()) ?? []
            // Das Atlassian-Team-Feld ist ein Custom Field (Typ "team" bzw.
            // rm-teams-…); Fallback: Feld, das schlicht "Team" heißt.
            let teamField = fields.first {
                $0.schema?.type == "team" || $0.schema?.custom?.lowercased().contains("rm-teams") == true
            } ?? fields.first { $0.name == "Team" }
            teamFieldId = teamField?.id
            teamFieldName = teamField?.name
        }
        if teams.isEmpty, let fieldName = teamFieldName {
            let results = (try? await client.teamSuggestions(fieldName: fieldName, query: "")) ?? []
            teams = results.map {
                TeamOption(id: $0.value, name: Self.stripHTML($0.displayName ?? $0.value))
            }
        }
        Log.app.info("CreateIssue: \(self.projects.count) Projekte, \(self.teams.count) Teams, Teamfeld \(self.teamFieldId ?? "—", privacy: .public)")
    }

    func issueTypes(projectKey: String) async -> [CreateMetaIssueType] {
        if let cached = issueTypesCache[projectKey] { return cached }
        guard let client = appState.currentClient() else { return [] }
        let types = ((try? await client.createMetaIssueTypes(projectKey: projectKey)) ?? [])
            .filter { $0.subtask != true }
        issueTypesCache[projectKey] = types
        return types
    }

    func components(projectKey: String) async -> [ProjectComponentDTO] {
        if let cached = componentsCache[projectKey] { return cached }
        guard let client = appState.currentClient() else { return [] }
        let components = (try? await client.projectComponents(projectKey: projectKey)) ?? []
        componentsCache[projectKey] = components
        return components
    }

    // MARK: - Vorbelegung

    /// Beim Ansehen eines Issues dessen Projekt/Typ/Team/Komponenten als
    /// „zuletzt angesehen"-Vorbelegung übernehmen (ein kleiner Raw-Request,
    /// weil das Team-Feld eine dynamische Custom-Field-ID hat).
    func captureViewedIssue(key: String) async {
        guard let client = appState.currentClient(),
              let base = appState.siteBaseURL else { return }
        var fields = "project,components,issuetype"
        if let teamFieldId { fields += ",\(teamFieldId)" }
        guard let data = try? await client.fetchData(
                  from: base.absoluteString + "/rest/api/3/issue/\(key)?fields=\(fields)"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fieldsDict = json["fields"] as? [String: Any] else { return }

        var defaults = Defaults()
        defaults.projectKey = (fieldsDict["project"] as? [String: Any])?["key"] as? String
        defaults.issueTypeId = (fieldsDict["issuetype"] as? [String: Any])?["id"] as? String
        if let components = fieldsDict["components"] as? [[String: Any]] {
            defaults.componentIds = components.compactMap { $0["id"] as? String }
        }
        if let teamFieldId {
            if let team = fieldsDict[teamFieldId] as? [String: Any] {
                defaults.teamId = team["id"] as? String
                defaults.teamName = (team["name"] as? String) ?? (team["title"] as? String)
            } else if let teamId = fieldsDict[teamFieldId] as? String {
                defaults.teamId = teamId
            }
        }
        lastViewed = defaults
        Self.persist(defaults, key: Self.lastViewedKey)
    }

    // MARK: - Anlegen

    /// Legt das Ticket an und merkt sich die Werte als neue Vorbelegung.
    /// Gibt den neuen Key zurück.
    func create(projectKey: String, issueTypeId: String, summary: String,
                descriptionMarkdown: String, teamId: String?,
                componentIds: [String]) async throws -> String {
        guard let client = appState.currentClient() else {
            throw JiraError.api(message: "Nicht mit Jira verbunden.")
        }
        var fields: [String: Any] = [
            "project": ["key": projectKey],
            "issuetype": ["id": issueTypeId],
            "summary": summary,
        ]
        let description = descriptionMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty {
            fields["description"] = markdownToADFDoc(description, siteBaseURL: appState.siteBaseURL)
        }
        if !componentIds.isEmpty {
            fields["components"] = componentIds.map { ["id": $0] }
        }
        if let teamId, let teamFieldId {
            fields[teamFieldId] = teamId
        }

        let created = try await client.createIssue(fields: fields)
        var defaults = Defaults(projectKey: projectKey, issueTypeId: issueTypeId,
                                teamId: teamId, componentIds: componentIds)
        defaults.teamName = teams.first { $0.id == teamId }?.name ?? lastViewed?.teamName
        lastCreated = defaults
        Self.persist(defaults, key: Self.lastCreatedKey)
        Log.app.info("Issue angelegt: \(created.key, privacy: .public)")
        return created.key
    }

    // MARK: - Helpers

    private static func stripHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func persist(_ defaults: Defaults, key: String) {
        if let data = try? JSONEncoder().encode(defaults) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func loadDefaults(key: String) -> Defaults? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Defaults.self, from: data)
    }
}
