import Foundation

// MARK: - Issue-Search (POST /rest/api/3/search/jql)

struct IssueSearchResponse: Decodable, Sendable {
    let issues: [IssueDTO]
    let nextPageToken: String?
    let isLast: Bool?
}

struct IssueDTO: Decodable, Sendable {
    let id: String
    let key: String
    let fields: IssueFields
}

struct IssueFields: Decodable, Sendable {
    let summary: String
    let updated: String
    let status: NamedDTO?
    let assignee: UserDTO?
}

struct NamedDTO: Decodable, Sendable {
    let name: String
}

// MARK: - User

struct UserDTO: Decodable, Sendable {
    let accountId: String?
    let displayName: String?
    let avatarUrls: [String: String]?

    /// Atlassian liefert Avatare in den Größen 16/24/32/48; wir nehmen 48px.
    var avatar48: String? { avatarUrls?["48x48"] }
}

// MARK: - Kommentare (GET /rest/api/3/issue/{key}/comment)

struct CommentsResponse: Decodable, Sendable {
    let comments: [CommentDTO]
}

struct CommentDTO: Decodable, Sendable {
    let id: String
    let author: UserDTO?
    let created: String
    let body: ADFNode?

    var bodyText: String { body?.plainText() ?? "" }
}

// MARK: - Changelog (GET /rest/api/3/issue/{key}/changelog)

struct ChangelogResponse: Decodable, Sendable {
    let values: [ChangeHistory]
    let total: Int?
    let startAt: Int?
}

struct ChangeHistory: Decodable, Sendable {
    let id: String
    let author: UserDTO?
    let created: String
    let items: [ChangeItem]
}

struct ChangeItem: Decodable, Sendable {
    let field: String
    let fromString: String?
    let toString: String?
}

// MARK: - Atlassian Document Format

/// ADF-Knoten inkl. Marks (Link/Bold/…) und Attrs (Mention/Emoji). `Codable`,
/// damit wir das Roh-ADF für reiches Rendering wieder serialisieren können.
/// Die SwiftUI-Darstellung (`attributedText()`) liegt in `ADFRendering.swift`.
struct ADFNode: Codable, Sendable {
    let type: String?
    let text: String?
    let content: [ADFNode]?
    let marks: [ADFMark]?
    let attrs: ADFAttrs?

    /// Plaintext-Reduktion (für Listen-Vorschau & Push-Body). Mentions/Emojis
    /// werden über ihren `text`-Attribut-Wert eingesetzt.
    func plainText() -> String {
        var out = ""
        append(into: &out)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func append(into out: inout String) {
        switch type {
        case "mention":
            out += attrs?.text ?? ""
        case "emoji":
            out += attrs?.text ?? attrs?.shortName ?? ""
        case "hardBreak":
            out += "\n"
        default:
            if let text { out += text }
        }
        content?.forEach { $0.append(into: &out) }
        if type == "paragraph" { out += "\n" }
    }
}

struct ADFMark: Codable, Sendable {
    let type: String?
    let attrs: ADFAttrs?
}

struct ADFAttrs: Codable, Sendable {
    let href: String?
    let url: String?
    let text: String?
    let shortName: String?
}
