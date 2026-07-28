import Foundation

// MARK: - Issue-Detail (GET /rest/api/3/issue/{key})

/// Vollständige Issue-Daten für die Detail-Ansicht. Bewusst getrennt von den
/// schlanken Such-DTOs (`IssueDTO`), damit der Sync-Pfad unberührt bleibt.
struct IssueDetailDTO: Decodable, Sendable {
    let id: String
    let key: String
    let fields: IssueDetailFields
}

struct IssueDetailFields: Decodable, Sendable {
    let summary: String
    let description: ADFNode?
    let status: StatusDTO?
    let assignee: UserDTO?
    let reporter: UserDTO?
    let parent: ParentIssueDTO?
    let issuelinks: [IssueLinkDTO]?
    let attachment: [AttachmentDTO]?
    let issuetype: IssueTypeDTO?
    let project: ProjectRefDTO?
    let updated: String?
    let components: [ProjectComponentDTO]?
    let labels: [String]?
    let fixVersions: [FixVersionDTO]?
}

struct FixVersionDTO: Codable, Sendable {
    let id: String?
    let name: String?
}

/// Projekt-Version (GET /rest/api/3/project/{key}/versions) — fürs
/// Fix-Version-Dropdown.
struct VersionDTO: Codable, Sendable, Identifiable {
    let id: String
    let name: String
    let released: Bool?
    let archived: Bool?

    /// Numerische Komponenten des Namens ("6.42.3" → [6, 42, 3]) — für
    /// echte Versions-Sortierung statt alphabetischer ("6.9" > "6.41" wäre
    /// sonst falsch herum).
    var numericComponents: [Int] {
        name.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    /// Absteigend: höchste Version zuerst; Namen ohne Zahlen ans Ende
    /// (alphabetisch).
    static func sortedDescending(_ versions: [VersionDTO]) -> [VersionDTO] {
        versions.sorted { a, b in
            let ka = a.numericComponents
            let kb = b.numericComponents
            if ka.isEmpty != kb.isEmpty { return kb.isEmpty }
            if ka == kb { return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending }
            for (x, y) in zip(ka, kb) where x != y {
                return x > y
            }
            return ka.count > kb.count
        }
    }
}

/// GET /rest/api/3/label — alle Labels der Site (fürs Vorschlagen).
struct LabelsResponse: Decodable, Sendable {
    let values: [String]
    let isLast: Bool?
}

struct StatusDTO: Decodable, Sendable {
    let name: String
    let statusCategory: StatusCategoryDTO?
}

/// `key` ist "new" (To Do, grau), "indeterminate" (In Progress, blau)
/// oder "done" (grün) — für die Status-Badge-Farbe.
struct StatusCategoryDTO: Codable, Sendable {
    let key: String?
}

struct IssueTypeDTO: Codable, Sendable {
    let id: String?
    let name: String?
    let iconUrl: String?
    /// Jira-Hierarchie: -1 = Sub-Task, 0 = Story/Bug/Task, 1+ = Epic und
    /// darüber. Sprachunabhängig — deshalb Vorrang vor dem Typnamen.
    let hierarchyLevel: Int?
    let subtask: Bool?

    var isSubtask: Bool {
        if let hierarchyLevel { return hierarchyLevel < 0 }
        if let subtask { return subtask }
        return ["sub-task", "subtask", "unteraufgabe"].contains(name?.lowercased() ?? "")
    }

    /// Epic-Ebene oder höher — die Ebene, auf der wir „Themen" gruppieren.
    var isEpicLevel: Bool {
        if let hierarchyLevel { return hierarchyLevel >= 1 }
        return name?.lowercased() == "epic"
    }
}

struct ProjectRefDTO: Decodable, Sendable {
    let key: String?
}

struct ParentIssueDTO: Decodable, Sendable {
    let key: String
    let fields: Fields?

    struct Fields: Decodable, Sendable {
        let summary: String?
        let status: StatusDTO?
        let issuetype: IssueTypeDTO?
    }
}

// MARK: - Issue-Links

struct IssueLinkDTO: Decodable, Sendable, Identifiable {
    let id: String
    let type: IssueLinkTypeDTO
    /// Genau eines von beiden ist gesetzt — je nach Richtung des Links.
    let inwardIssue: LinkedIssueDTO?
    let outwardIssue: LinkedIssueDTO?

    /// Das verlinkte Gegenüber inkl. Richtungs-Beschriftung ("blocks", …).
    ///
    /// Jira projiziert im `issuelinks` eines Issues nur die *andere* Seite —
    /// unter dem Schlüssel ihrer Rolle im Link-Objekt. Steht der Partner unter
    /// `outwardIssue`, ist dieses Issue die inward-Seite und damit die aktive:
    /// Beschriftung `type.outward` ("blocks"). Siehe auch
    /// `JiraClient.createIssueLink`.
    var other: (issue: LinkedIssueDTO, label: String)? {
        if let outwardIssue { return (outwardIssue, type.outward ?? type.name ?? "verlinkt") }
        if let inwardIssue { return (inwardIssue, type.inward ?? type.name ?? "verlinkt") }
        return nil
    }
}

struct IssueLinkTypeDTO: Decodable, Sendable {
    let id: String?
    let name: String?
    let inward: String?
    let outward: String?
}

struct IssueLinkTypesResponse: Decodable, Sendable {
    let issueLinkTypes: [IssueLinkTypeDTO]
}

struct LinkedIssueDTO: Decodable, Sendable {
    let key: String
    let fields: Fields?

    struct Fields: Decodable, Sendable {
        let summary: String?
        let status: StatusDTO?
        let issuetype: IssueTypeDTO?
    }
}

// MARK: - Attachments

struct AttachmentDTO: Decodable, Sendable, Identifiable {
    let id: String
    let filename: String
    let mimeType: String?
    /// Authentifizierter Download-Endpoint (redirectet zur signierten Media-URL).
    let content: String
    let thumbnail: String?
    let size: Int?
    let created: String?
    let author: UserDTO?

    var isImage: Bool { mimeType?.hasPrefix("image/") == true }
    var isVideo: Bool { mimeType?.hasPrefix("video/") == true }
}

/// Antwort von POST /issue/{key}/attachments — ein Array der neuen Anhänge.
typealias AttachmentUploadResponse = [AttachmentDTO]

// MARK: - Issue-Picker (GET /rest/api/3/issue/picker)

struct IssuePickerResponse: Decodable, Sendable {
    let sections: [Section]

    struct Section: Decodable, Sendable {
        let label: String?
        let issues: [Suggestion]
    }

    struct Suggestion: Decodable, Sendable, Identifiable {
        let id: Int?
        let key: String
        /// Klartext-Zusammenfassung (ohne die HTML-Hervorhebungen von `summary`).
        let summaryText: String?
    }

    var allSuggestions: [Suggestion] {
        var seen = Set<String>()
        return sections.flatMap(\.issues).filter { seen.insert($0.key).inserted }
    }
}
