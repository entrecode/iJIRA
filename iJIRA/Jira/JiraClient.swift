import Foundation

/// Minimaler Jira-Cloud-REST-Client mit Basic-Auth (E-Mail + API-Token).
struct JiraClient: Sendable {
    let baseURL: URL
    let email: String
    let apiToken: String

    /// Eigene Session statt `URLSession.shared`: deren Default-Resource-Timeout
    /// beträgt 7 Tage — ein nach Sleep/Wake halbtoter Request würde den
    /// Sync-Loop dauerhaft blockieren. Hier ist nach spätestens 60 s Schluss.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    // MARK: - Endpoints

    func currentUser() async throws -> Myself {
        try await get("rest/api/3/myself", as: Myself.self)
    }

    /// Issues, die mich betreffen und sich kürzlich geändert haben.
    /// Quelle für abgeleitete „direkte Notifications" (siehe Konzept §5.1).
    ///
    /// Mentions: ein JQL-Feld `mentioned` existiert nicht — Jira legt Mentions
    /// intern als `[~accountid:…]` ab, deshalb per Text-Suche über
    /// `comment ~ currentUser()` / `description ~ currentUser()` (offizieller
    /// Workaround laut Atlassian-Doku).
    ///
    /// Paginiert über `nextPageToken`, damit nach langer Downtime auch mehr
    /// als eine Seite Ergebnisse ankommt (Obergrenze `maxPages`).
    func searchInvolvedIssues(pageSize: Int = 100, maxPages: Int = 5) async throws -> [IssueDTO] {
        let jql = "(assignee = currentUser() OR reporter = currentUser() OR watcher = currentUser()"
            + " OR comment ~ currentUser() OR description ~ currentUser())"
            + " AND updated >= -7d ORDER BY updated DESC"
        var issues: [IssueDTO] = []
        var nextPageToken: String?
        for _ in 0..<maxPages {
            var body: [String: Any] = [
                "jql": jql,
                "maxResults": pageSize,
                "fields": ["summary", "updated", "status", "assignee"],
            ]
            if let nextPageToken { body["nextPageToken"] = nextPageToken }
            let response: IssueSearchResponse = try await post("rest/api/3/search/jql",
                                                               json: body,
                                                               as: IssueSearchResponse.self)
            issues += response.issues
            guard response.isLast != true, let token = response.nextPageToken else { break }
            nextPageToken = token
        }
        return issues
    }

    func comments(issueKey: String, maxResults: Int = 50) async throws -> [CommentDTO] {
        let response: CommentsResponse = try await get(
            "rest/api/3/issue/\(issueKey)/comment?orderBy=-created&maxResults=\(maxResults)",
            as: CommentsResponse.self)
        return response.comments
    }

    /// Eine Seite älterer Kommentare (neueste zuerst) — für das Nachladen der
    /// Historie in der Konversationsansicht. `startAt` = Anzahl bereits
    /// bekannter Kommentare.
    func commentsPage(issueKey: String, startAt: Int, maxResults: Int = 50) async throws -> CommentsResponse {
        try await get(
            "rest/api/3/issue/\(issueKey)/comment?orderBy=-created&startAt=\(startAt)&maxResults=\(maxResults)",
            as: CommentsResponse.self)
    }

    @discardableResult
    func addComment(issueKey: String, adfBody: [String: Any]) async throws -> CommentDTO {
        try await post("rest/api/3/issue/\(issueKey)/comment", json: adfBody, as: CommentDTO.self)
    }

    /// Changelog-Einträge — garantiert die *neuesten*. Jira paginiert den
    /// Changelog älteste zuerst; bei mehr Einträgen als `maxResults` muss
    /// deshalb die letzte Seite geholt werden, sonst sieht man bei
    /// langlebigen Issues neue Statuswechsel nie.
    func changelog(issueKey: String, maxResults: Int = 40) async throws -> [ChangeHistory] {
        let first: ChangelogResponse = try await get(
            "rest/api/3/issue/\(issueKey)/changelog?maxResults=\(maxResults)",
            as: ChangelogResponse.self)
        guard let total = first.total, total > first.values.count else { return first.values }
        let offset = max(0, total - maxResults)
        let last: ChangelogResponse = try await get(
            "rest/api/3/issue/\(issueKey)/changelog?startAt=\(offset)&maxResults=\(maxResults)",
            as: ChangelogResponse.self)
        return last.values
    }

    // MARK: - Request plumbing

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        var request = try makeRequest(path)
        request.httpMethod = "GET"
        let (data, response) = try await Self.session.data(for: request)
        return try decode(T.self, data: data, response: response)
    }

    private func post<T: Decodable>(_ path: String, json: [String: Any], as type: T.Type) async throws -> T {
        var request = try makeRequest(path)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        let (data, response) = try await Self.session.data(for: request)
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
            // `Retry-After` (Sekunden) mitgeben, damit der Sync exakt so lange
            // wartet statt generisch zu backoffen. HTTP-Datum-Variante ignorieren
            // wir — Jira Cloud sendet Sekunden.
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                .flatMap { TimeInterval($0) }
            throw JiraError.rateLimited(retryAfter: retryAfter)
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
    case rateLimited(retryAfter: TimeInterval?)
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
