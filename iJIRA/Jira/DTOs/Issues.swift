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

struct UserDTO: Decodable, Sendable, Identifiable, Hashable {
    let accountId: String?
    let displayName: String?
    let avatarUrls: [String: String]?
    /// "atlassian" = Mensch, "app"/"customer" = Bot/Portal — für die
    /// Personenauswahl werden nur echte Accounts angeboten.
    let accountType: String?
    let active: Bool?

    var id: String { accountId ?? displayName ?? UUID().uuidString }

    /// Atlassian liefert Avatare in den Größen 16/24/32/48; wir nehmen 48px.
    var avatar48: String? { avatarUrls?["48x48"] }

    static func == (lhs: UserDTO, rhs: UserDTO) -> Bool { lhs.accountId == rhs.accountId }
    func hash(into hasher: inout Hasher) { hasher.combine(accountId) }
}

// MARK: - Kommentare (GET /rest/api/3/issue/{key}/comment)

struct CommentsResponse: Decodable, Sendable {
    let comments: [CommentDTO]
    let total: Int?
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
        // taskItem trägt Inline-Inhalt direkt (ohne Absatz) — sonst kleben
        // aufeinanderfolgende Aufgaben aneinander.
        if type == "paragraph" || type == "taskItem" { out += "\n" }
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
    /// Mention-AccountId bzw. Media-UUID.
    let id: String?
    /// Heading-Level (1–6).
    let level: Int?
    /// Media: Dateiname (alt-Text) — einziger Weg, ADF-Media-Knoten den
    /// REST-Attachments zuzuordnen (die Media-UUID taucht dort nicht auf).
    let alt: String?
    /// Media-Typ ("file") bzw. Panel-Typ ("info", "warning", …).
    let type: String?
    /// codeBlock-Sprache.
    let language: String?
    // Media-Roundtrip: ohne diese Attribute würde ein re-encodeter
    /// Media-Knoten beim Speichern der Beschreibung kaputtgehen.
    let collection: String?
    let width: Double?
    let height: Double?
    let occurrenceKey: String?
    let layout: String?
    /// orderedList: Startnummer.
    let order: Int?
    /// taskList/taskItem: Pflicht-ID bzw. Status ("TODO"/"DONE").
    let localId: String?
    let state: String?
    // Tabellen-Roundtrip: Zellen-Verbund, Spaltenbreiten, Hintergrund und
    // Tabellen-Optionen — sonst gehen sie beim Speichern der Beschreibung verloren.
    let colspan: Int?
    let rowspan: Int?
    let colwidth: [Double]?
    let background: String?
    let isNumberColumnEnabled: Bool?
    let displayMode: String?
}
