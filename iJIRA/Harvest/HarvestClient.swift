import Foundation

/// Schlanker Harvest-API-v2-Client (Personal Access Token + Account-ID).
/// Header-Konventionen laut Harvest-Doku; JSON kommt in snake_case.
struct HarvestClient: Sendable {
    let accessToken: String
    let accountId: String

    private static let base = URL(string: "https://api.harvestapp.com/v2")!

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    // MARK: - Endpoints

    func me() async throws -> HarvestUser {
        try await request("GET", "users/me", as: HarvestUser.self)
    }

    /// Projekte + Tasks, denen der Nutzer zugewiesen ist (für die Picker).
    func projectAssignments() async throws -> [HarvestProjectAssignment] {
        var all: [HarvestProjectAssignment] = []
        var page = 1
        for _ in 0..<10 {
            let response: HarvestProjectAssignmentsResponse = try await request(
                "GET", "users/me/project_assignments?per_page=100&page=\(page)",
                as: HarvestProjectAssignmentsResponse.self)
            all += response.projectAssignments
            guard response.nextPage != nil else { break }
            page += 1
        }
        return all
    }

    /// Meine Zeiteinträge im konfigurierten Projekt (ab `fromISODate`).
    /// Das Issue-Matching passiert lokal (external_reference ODER Jira-Key in
    /// den Notes) — so zählen auch extern in Harvest erfasste Zeiten.
    func projectTimeEntries(projectId: Int, userId: Int,
                            fromISODate: String) async throws -> [HarvestTimeEntry] {
        var all: [HarvestTimeEntry] = []
        var page = 1
        for _ in 0..<20 {
            let response: HarvestTimeEntriesResponse = try await request(
                "GET",
                "time_entries?project_id=\(projectId)&user_id=\(userId)&from=\(fromISODate)&per_page=100&page=\(page)",
                as: HarvestTimeEntriesResponse.self)
            all += response.timeEntries
            guard response.nextPage != nil else { break }
            page += 1
        }
        return all
    }

    @discardableResult
    func createTimeEntry(projectId: Int, taskId: Int, spentDate: String, hours: Double,
                         notes: String, externalReference: [String: String]) async throws -> HarvestTimeEntry {
        let body: [String: Any] = [
            "project_id": projectId,
            "task_id": taskId,
            "spent_date": spentDate,
            "hours": hours,
            "notes": notes,
            "external_reference": externalReference,
        ]
        return try await request("POST", "time_entries", json: body, as: HarvestTimeEntry.self)
    }

    // MARK: - Plumbing

    private func request<T: Decodable>(_ method: String, _ path: String,
                                       json: [String: Any]? = nil, as type: T.Type) async throws -> T {
        guard let url = URL(string: Self.base.absoluteString + "/" + path) else {
            throw HarvestError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(accountId, forHTTPHeaderField: "Harvest-Account-Id")
        request.setValue("iJIRA (https://github.com/entrecode/iJIRA)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }

        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HarvestError.invalidResponse }
        switch http.statusCode {
        case 200..<300:
            break
        case 401:
            throw HarvestError.unauthorized
        default:
            // Harvest liefert Fehlerdetails als {"message": "…"}.
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["message"] as? String }
            throw HarvestError.http(status: http.statusCode, message: message)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw HarvestError.decoding
        }
    }
}

enum HarvestError: Error {
    case invalidResponse
    case decoding
    case unauthorized
    case http(status: Int, message: String?)

    var userMessage: String {
        switch self {
        case .invalidResponse: return "Unerwartete Antwort von Harvest."
        case .decoding: return "Harvest-Antwort konnte nicht gelesen werden."
        case .unauthorized: return "Harvest: Token oder Account-ID ungültig."
        case .http(let status, let message):
            return "Harvest: \(message ?? "Fehler") (HTTP \(status))"
        }
    }
}

// MARK: - DTOs (Property-Namen camelCase via convertFromSnakeCase)

struct HarvestUser: Decodable, Sendable {
    let id: Int
    let firstName: String?
    let lastName: String?

    var displayName: String {
        [firstName, lastName].compactMap { $0 }.joined(separator: " ")
    }
}

struct HarvestProjectAssignmentsResponse: Decodable, Sendable {
    let projectAssignments: [HarvestProjectAssignment]
    let nextPage: Int?
}

struct HarvestProjectAssignment: Decodable, Sendable, Identifiable {
    let id: Int
    let project: HarvestProjectRef
    let client: HarvestClientRef?
    let taskAssignments: [HarvestTaskAssignment]
}

struct HarvestProjectRef: Decodable, Sendable {
    let id: Int
    let name: String
}

struct HarvestClientRef: Decodable, Sendable {
    let name: String?
}

struct HarvestTaskAssignment: Decodable, Sendable, Identifiable {
    let id: Int
    let task: HarvestTaskRef
    let billable: Bool?
}

struct HarvestTaskRef: Decodable, Sendable {
    let id: Int
    let name: String
}

struct HarvestTimeEntriesResponse: Decodable, Sendable {
    let timeEntries: [HarvestTimeEntry]
    let nextPage: Int?
}

struct HarvestTimeEntry: Decodable, Sendable {
    let id: Int
    let hours: Double?
    let spentDate: String?
    let notes: String?
    let externalReference: HarvestExternalReference?
}

struct HarvestExternalReference: Decodable, Sendable {
    let id: String?
    let permalink: String?
}
