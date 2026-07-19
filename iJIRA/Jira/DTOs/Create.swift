import Foundation

// MARK: - Projekte (GET /rest/api/3/project/search)

struct ProjectSummaryDTO: Codable, Sendable, Identifiable {
    let id: String
    let key: String
    let name: String
}

struct ProjectSearchResponse: Decodable, Sendable {
    let values: [ProjectSummaryDTO]
    let isLast: Bool?
}

// MARK: - Createmeta (GET /rest/api/3/issue/createmeta/{key}/issuetypes)

struct CreateMetaIssueTypesResponse: Decodable, Sendable {
    let issueTypes: [CreateMetaIssueType]
}

struct CreateMetaIssueType: Decodable, Sendable, Identifiable {
    let id: String
    let name: String
    let subtask: Bool?
}

// MARK: - Komponenten (GET /rest/api/3/project/{key}/components)

struct ProjectComponentDTO: Codable, Sendable, Identifiable {
    let id: String
    let name: String
}

// MARK: - Felder & Team-Suggestions

/// GET /rest/api/3/field — zum Auffinden des Team-Custom-Fields.
struct FieldDTO: Decodable, Sendable {
    let id: String
    let name: String?
    let schema: Schema?

    struct Schema: Decodable, Sendable {
        let type: String?
        let custom: String?
    }
}

/// GET /rest/api/3/jql/autocompletedata/suggestions — liefert für das
/// Team-Feld die verfügbaren Teams (value = Team-ID).
struct JQLSuggestionsResponse: Decodable, Sendable {
    let results: [Result]

    struct Result: Decodable, Sendable {
        let value: String
        /// Enthält HTML-Hervorhebungen (<b>…</b>) — vor Anzeige strippen.
        let displayName: String?
    }
}

// MARK: - Ergebnis (POST /rest/api/3/issue)

struct CreatedIssueDTO: Decodable, Sendable {
    let id: String
    let key: String
}
