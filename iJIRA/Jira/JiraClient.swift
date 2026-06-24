import Foundation

/// Minimaler Jira-Cloud-REST-Client mit Basic-Auth (E-Mail + API-Token).
struct JiraClient: Sendable {
    let baseURL: URL
    let email: String
    let apiToken: String

    // MARK: - Endpoints

    func currentUser() async throws -> Myself {
        try await get("rest/api/3/myself", as: Myself.self)
    }

    /// Issues, die mich betreffen und sich kürzlich geändert haben.
    /// Quelle für abgeleitete „direkte Notifications" (siehe Konzept §5.1).
    func searchInvolvedIssues(maxResults: Int = 30) async throws -> [IssueDTO] {
        let jql = "(assignee = currentUser() OR reporter = currentUser() OR watcher = currentUser())"
            + " AND updated >= -7d ORDER BY updated DESC"
        let body: [String: Any] = [
            "jql": jql,
            "maxResults": maxResults,
            "fields": ["summary", "updated", "status", "assignee"],
        ]
        let response: IssueSearchResponse = try await post("rest/api/3/search/jql",
                                                           json: body,
                                                           as: IssueSearchResponse.self)
        return response.issues
    }

    func comments(issueKey: String, maxResults: Int = 20) async throws -> [CommentDTO] {
        let response: CommentsResponse = try await get(
            "rest/api/3/issue/\(issueKey)/comment?orderBy=-created&maxResults=\(maxResults)",
            as: CommentsResponse.self)
        return response.comments
    }

    @discardableResult
    func addComment(issueKey: String, adfBody: [String: Any]) async throws -> CommentDTO {
        try await post("rest/api/3/issue/\(issueKey)/comment", json: adfBody, as: CommentDTO.self)
    }

    func changelog(issueKey: String, maxResults: Int = 20) async throws -> [ChangeHistory] {
        let response: ChangelogResponse = try await get(
            "rest/api/3/issue/\(issueKey)/changelog?maxResults=\(maxResults)",
            as: ChangelogResponse.self)
        return response.values
    }

    // MARK: - Request plumbing

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        var request = try makeRequest(path)
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        return try decode(T.self, data: data, response: response)
    }

    private func post<T: Decodable>(_ path: String, json: [String: Any], as type: T.Type) async throws -> T {
        var request = try makeRequest(path)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        let (data, response) = try await URLSession.shared.data(for: request)
        return try decode(T.self, data: data, response: response)
    }

    private func makeRequest(_ path: String) throws -> URLRequest {
        // baseURL ist ohne Trailing-Slash normalisiert; path kann eine
        // Query-Komponente enthalten, daher String-Komposition statt
        // appendingPathComponent (das den "?" escapen würde).
        guard let url = URL(string: baseURL.absoluteString + "/" + path) else {
            throw JiraError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func decode<T: Decodable>(_ type: T.Type, data: Data, response: URLResponse) throws -> T {
        guard let http = response as? HTTPURLResponse else { throw JiraError.invalidResponse }
        switch http.statusCode {
        case 200..<300:
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw JiraError.decoding
            }
        case 401, 403:
            throw JiraError.unauthorized
        case 404:
            throw JiraError.notFound
        case 429:
            throw JiraError.rateLimited
        default:
            throw JiraError.http(status: http.statusCode)
        }
    }

    private var authorizationHeader: String {
        let raw = "\(email):\(apiToken)"
        return "Basic " + Data(raw.utf8).base64EncodedString()
    }
}

enum JiraError: Error {
    case invalidResponse
    case decoding
    case unauthorized
    case notFound
    case rateLimited
    case http(status: Int)

    var userMessage: String {
        switch self {
        case .invalidResponse:
            return "Unerwartete Antwort vom Server."
        case .decoding:
            return "Antwort konnte nicht gelesen werden."
        case .unauthorized:
            return "Anmeldung fehlgeschlagen – E-Mail oder API-Token prüfen."
        case .notFound:
            return "Endpoint nicht gefunden – stimmt die Site-URL?"
        case .rateLimited:
            return "Zu viele Anfragen – kurz warten."
        case .http(let status):
            return "Serverfehler (HTTP \(status))."
        }
    }
}
