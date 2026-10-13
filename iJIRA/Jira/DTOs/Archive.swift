import Foundation

// MARK: - Issue-Archiv (GraphQL-Gateway, siehe JiraClient.archiveStatus)

/// Archiv-Status eines Issues, wie ihn die Detail-Ansicht braucht.
struct IssueArchiveStatus: Sendable {
    /// Atlassian Resource Identifier (`ari:cloud:jira:<cloudId>:issue/<id>`) —
    /// die ID, die die Unarchive-Mutation erwartet.
    let ari: String
    let isArchived: Bool
    let archivedOn: Date?
    let archivedBy: String?
}

struct GraphQLResponse<T: Decodable>: Decodable {
    let data: T?
    let errors: [GraphQLErrorDTO]?
}

struct GraphQLErrorDTO: Decodable, Sendable {
    let message: String?
}

struct ArchiveStatusData: Decodable {
    let jira: Jira?

    struct Jira: Decodable {
        let issueByKey: Issue?
    }

    struct Issue: Decodable {
        let id: String
        let isArchived: Bool?
        let archivedOn: String?
        let archivedBy: ArchivedBy?
    }

    struct ArchivedBy: Decodable {
        let name: String?
    }
}

struct UnarchiveData: Decodable {
    let unarchiveIssue: Payload?

    enum CodingKeys: String, CodingKey {
        case unarchiveIssue = "jira_unarchiveIssue"
    }

    struct Payload: Decodable {
        let success: Bool
        let errors: [GraphQLErrorDTO]?
    }
}

/// PUT /rest/api/3/issue/unarchive
struct UnarchiveRESTResponse: Decodable {
    let numberOfIssuesUpdated: Int?
}

/// GET /_edge/tenant_info
struct TenantInfo: Decodable {
    let cloudId: String
}

/// Cloud-ID pro Site — ändert sich nie, ein Lookup pro App-Lauf genügt.
actor CloudIdCache {
    static let shared = CloudIdCache()
    private var values: [String: String] = [:]

    func value(for site: String) -> String? { values[site] }
    func store(_ cloudId: String, for site: String) { values[site] = cloudId }
}
