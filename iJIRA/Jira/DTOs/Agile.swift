import Foundation

// MARK: - Boards (GET /rest/agile/1.0/board)

struct BoardDTO: Codable, Sendable, Identifiable {
    let id: Int
    let name: String
    /// "scrum" (Sprints) oder "kanban".
    let type: String
    let location: Location?

    struct Location: Codable, Sendable {
        let projectKey: String?
        let displayName: String?
    }
}

struct BoardsResponse: Decodable, Sendable {
    let values: [BoardDTO]
    let isLast: Bool?
}

// MARK: - Board-Konfiguration (Spalten → Status-Zuordnung)

struct BoardConfigurationDTO: Decodable, Sendable {
    let columnConfig: ColumnConfig

    struct ColumnConfig: Decodable, Sendable {
        let columns: [Column]
    }

    struct Column: Decodable, Sendable {
        let name: String
        let statuses: [StatusRef]

        struct StatusRef: Decodable, Sendable {
            let id: String
        }
    }
}

// MARK: - Sprints

struct SprintDTO: Decodable, Sendable, Identifiable {
    let id: Int
    let name: String
    let state: String?
    let startDate: String?
    let endDate: String?
}

struct SprintsResponse: Decodable, Sendable {
    let values: [SprintDTO]
}

// MARK: - Board-Issues (Karten)

/// Issue-Daten für Board-Karten und Backlog-Zeilen. Codable, weil die
/// Board-Snapshots auf Platte persistiert werden (Cache-first-Rendering).
struct BoardIssueDTO: Codable, Sendable, Identifiable {
    let id: String
    let key: String
    let fields: Fields

    struct Fields: Codable, Sendable {
        let summary: String
        let updated: String?
        let status: Status?
        let priority: PriorityDTO?
        let issuetype: IssueTypeDTO?
    }

    /// Status inkl. ID (die Detail-DTOs brauchen sie nicht, das Board schon —
    /// die Spalten-Zuordnung läuft über Status-IDs).
    struct Status: Codable, Sendable {
        let id: String?
        let name: String?
        let statusCategory: StatusCategoryDTO?
    }

    var updatedDate: Date? { fields.updated.flatMap { JiraDate.parse($0) } }
}

struct PriorityDTO: Codable, Sendable {
    let name: String?
}

/// Antwortform der Agile-Issue-Endpoints UND von /rest/api/3/search/jql —
/// beide liefern `issues`; die Paging-Felder unterscheiden sich (optional).
struct BoardIssuesResponse: Decodable, Sendable {
    let issues: [BoardIssueDTO]
    let total: Int?
    let nextPageToken: String?
    let isLast: Bool?
}

// MARK: - Transitions (Statuswechsel per DnD)

struct TransitionDTO: Decodable, Sendable, Identifiable {
    let id: String
    let name: String?
    let to: ToStatus?

    struct ToStatus: Decodable, Sendable {
        let id: String?
        let name: String?
    }
}

struct TransitionsResponse: Decodable, Sendable {
    let transitions: [TransitionDTO]
}
