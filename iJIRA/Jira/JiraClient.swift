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

    /// Für Attachment-Up-/Downloads: gleiche Härtung, aber großzügigere
    /// Limits (Videos!) — die 60-s-Grenze der API-Session würde große
    /// Transfers abbrechen.
    private static let mediaSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
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

    /// Alle Kommentare aufsteigend (für die Detail-Ansicht), mit Seiten-Limit
    /// als Schutz vor Monster-Issues.
    func allComments(issueKey: String, pageSize: Int = 100, maxPages: Int = 5) async throws -> [CommentDTO] {
        var all: [CommentDTO] = []
        for _ in 0..<maxPages {
            let response: CommentsResponse = try await get(
                "rest/api/3/issue/\(issueKey)/comment?orderBy=created&startAt=\(all.count)&maxResults=\(pageSize)",
                as: CommentsResponse.self)
            all += response.comments
            if response.comments.isEmpty || all.count >= (response.total ?? 0) { break }
        }
        return all
    }

    @discardableResult
    func addComment(issueKey: String, adfBody: [String: Any]) async throws -> CommentDTO {
        try await post("rest/api/3/issue/\(issueKey)/comment", json: adfBody, as: CommentDTO.self)
    }

    // MARK: - Agile (Boards, Sprints, Board-Issues)

    private static let boardIssueFields = "summary,updated,status,priority,issuetype"

    /// Alle sichtbaren Boards (paginiert, alle Spaces).
    func allBoards() async throws -> [BoardDTO] {
        var result: [BoardDTO] = []
        for _ in 0..<10 {
            let page: BoardsResponse = try await get(
                "rest/agile/1.0/board?startAt=\(result.count)&maxResults=50",
                as: BoardsResponse.self)
            result += page.values
            if page.isLast != false || page.values.isEmpty { break }
        }
        return result
    }

    func boardConfiguration(boardId: Int) async throws -> BoardConfigurationDTO {
        try await get("rest/agile/1.0/board/\(boardId)/configuration",
                      as: BoardConfigurationDTO.self)
    }

    func activeSprints(boardId: Int) async throws -> [SprintDTO] {
        try await get("rest/agile/1.0/board/\(boardId)/sprint?state=active",
                      as: SprintsResponse.self).values
    }

    /// Geplante (noch nicht gestartete) Sprints eines Boards — in Board-
    /// Reihenfolge, der erste ist also der nächste.
    func futureSprints(boardId: Int) async throws -> [SprintDTO] {
        try await get("rest/agile/1.0/board/\(boardId)/sprint?state=future&maxResults=50",
                      as: SprintsResponse.self).values
    }

    /// Aktive + geplante Sprints eines Boards (für die Sprint-Auswahl im Issue).
    func selectableSprints(boardId: Int) async throws -> [SprintDTO] {
        try await get("rest/agile/1.0/board/\(boardId)/sprint?state=active,future&maxResults=50",
                      as: SprintsResponse.self).values
    }

    /// Issue in einen Sprint verschieben (setzt das Sprint-Feld zuverlässig,
    /// anders als editIssue auf dem greenhopper-Custom-Field).
    func moveIssueToSprint(sprintId: Int, issueKey: String) async throws {
        try await sendNoContent(method: "POST",
                                path: "rest/agile/1.0/sprint/\(sprintId)/issue",
                                json: ["issues": [issueKey]])
    }

    /// Issue aus dem Sprint ins Backlog verschieben.
    func moveIssueToBacklog(issueKey: String) async throws {
        try await sendNoContent(method: "POST",
                                path: "rest/agile/1.0/backlog/issue",
                                json: ["issues": [issueKey]])
    }

    /// Meine Issues im Sprint (Scrum-Boards).
    func mySprintIssues(sprintId: Int) async throws -> [BoardIssueDTO] {
        let jql = encodeJQL("assignee = currentUser() ORDER BY rank")
        return try await get(
            "rest/agile/1.0/sprint/\(sprintId)/issue?jql=\(jql)&fields=\(Self.boardIssueFields)&maxResults=100",
            as: BoardIssuesResponse.self).issues
    }

    /// Meine Issues eines Kanban-Boards (kein Sprint; Done nur die letzten Tage).
    func myBoardIssues(boardId: Int) async throws -> [BoardIssueDTO] {
        let jql = encodeJQL("assignee = currentUser() AND (statusCategory != Done OR updated >= -7d) ORDER BY rank")
        return try await get(
            "rest/agile/1.0/board/\(boardId)/issue?jql=\(jql)&fields=\(Self.boardIssueFields)&maxResults=100",
            as: BoardIssuesResponse.self).issues
    }

    /// Meine offenen Issues, die in keinem aktiven Sprint sind (Backlog-Liste
    /// unter dem Board — global über alle Projekte).
    func myOpenIssuesOutsideSprints() async throws -> [BoardIssueDTO] {
        let body: [String: Any] = [
            "jql": "assignee = currentUser() AND statusCategory != Done"
                + " AND (sprint is EMPTY OR sprint not in openSprints())"
                + " ORDER BY updated DESC",
            "maxResults": 100,
            "fields": Self.boardIssueFields.components(separatedBy: ","),
        ]
        return try await post("rest/api/3/search/jql", json: body,
                              as: BoardIssuesResponse.self).issues
    }

    private func encodeJQL(_ jql: String) -> String {
        jql.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? jql
    }

    // MARK: - Review & Plan

    /// Wie `boardIssueFields`, plus Hierarchie und Zeiten. `worklog` kommt
    /// inline mit (die ersten 20 Einträge) — das erspart einen Request pro
    /// Issue; der Rest wird bei Bedarf über `worklogs(issueKey:startedAfter:)`
    /// nachgeladen.
    private static let reviewIssueFields =
        ["summary", "updated", "status", "priority", "issuetype", "parent", "timespent", "worklog"]

    /// Ohne Worklogs — für die Planungs-Abschnitte, wo keine Zeiten angezeigt
    /// werden (spart die deutlich größere Antwort).
    private static let planIssueFields =
        ["summary", "updated", "status", "priority", "issuetype", "parent"]

    /// Meine Issues eines bestimmten Sprints, inkl. Parent und Worklogs.
    /// Bewusst über `search/jql` statt den Agile-Endpoint: nur die Suche
    /// liefert `worklog` als Feld mit.
    func myIssues(sprintId: Int, includeWorklogs: Bool) async throws -> [BoardIssueDTO] {
        try await searchAllPages(
            jql: "sprint = \(sprintId) AND assignee = currentUser() ORDER BY rank",
            fields: includeWorklogs ? Self.reviewIssueFields : Self.planIssueFields)
    }

    /// Meine offenen Issues, die in *keinem* Sprint eingeplant sind — weder in
    /// einem laufenden noch in einem geplanten.
    func myUnplannedIssues() async throws -> [BoardIssueDTO] {
        try await searchAllPages(
            jql: "assignee = currentUser() AND statusCategory != Done"
                + " AND (sprint is EMPTY OR (sprint not in openSprints() AND sprint not in futureSprints()))"
                + " ORDER BY updated DESC",
            fields: Self.planIssueFields)
    }

    /// Issues per Key nachladen — für die Themen-Auflösung: über einer Sub-Task
    /// steht eine Story, das Epic („Thema") ist erst deren Parent.
    func issues(keys: [String]) async throws -> [BoardIssueDTO] {
        guard !keys.isEmpty else { return [] }
        var result: [BoardIssueDTO] = []
        // JQL-Längenlimit respektieren: in Blöcken abfragen.
        for chunk in stride(from: 0, to: keys.count, by: 80).map({
            Array(keys[$0..<min($0 + 80, keys.count)])
        }) {
            let list = chunk.map { "\"\($0)\"" }.joined(separator: ",")
            result += try await searchAllPages(jql: "key in (\(list))",
                                               fields: ["summary", "status", "issuetype", "parent"])
        }
        return result
    }

    /// Untergeordnete Vorgänge: bei einem Epic die enthaltenen Issues, bei
    /// einer Story die Sub-Tasks. Beide hängen am `parent`-Feld — gegen die
    /// Instanz geprüft, auch für die klassischen Epic-Kinder im
    /// company-managed Projekt —, deshalb genügt eine Abfrage für beide Fälle.
    func childIssues(parentKey: String) async throws -> [BoardIssueDTO] {
        try await searchAllPages(jql: "parent = \"\(parentKey)\" ORDER BY rank",
                                 fields: ["summary", "status", "issuetype", "parent"])
    }

    /// Worklogs eines Issues ab einem Zeitpunkt — Nachschlag für Issues mit
    /// mehr als 20 Einträgen (mehr liefert die Suche nicht inline).
    func worklogs(issueKey: String, startedAfter: Date) async throws -> [WorklogEntryDTO] {
        let millis = Int(startedAfter.timeIntervalSince1970 * 1000)
        return try await get(
            "rest/api/3/issue/\(issueKey)/worklog?startedAfter=\(millis)&maxResults=1000",
            as: WorklogPageDTO.self).worklogs
    }

    private func searchAllPages(jql: String, fields: [String],
                                pageSize: Int = 100, maxPages: Int = 8) async throws -> [BoardIssueDTO] {
        var all: [BoardIssueDTO] = []
        var nextPageToken: String?
        for _ in 0..<maxPages {
            var body: [String: Any] = ["jql": jql, "maxResults": pageSize, "fields": fields]
            if let nextPageToken { body["nextPageToken"] = nextPageToken }
            let page: BoardIssuesResponse = try await post("rest/api/3/search/jql", json: body,
                                                           as: BoardIssuesResponse.self)
            all += page.issues
            guard page.isLast != true, let token = page.nextPageToken else { break }
            nextPageToken = token
        }
        return all
    }

    // MARK: - Transitions (Statuswechsel)

    func transitions(issueKey: String) async throws -> [TransitionDTO] {
        try await get("rest/api/3/issue/\(issueKey)/transitions",
                      as: TransitionsResponse.self).transitions
    }

    func applyTransition(issueKey: String, transitionId: String) async throws {
        try await sendNoContent(method: "POST",
                                path: "rest/api/3/issue/\(issueKey)/transitions",
                                json: ["transition": ["id": transitionId]])
    }

    // MARK: - Issue anlegen

    func visibleProjects(maxResults: Int = 200) async throws -> [ProjectSummaryDTO] {
        try await get("rest/api/3/project/search?maxResults=\(maxResults)&orderBy=name",
                      as: ProjectSearchResponse.self).values
    }

    func createMetaIssueTypes(projectKey: String) async throws -> [CreateMetaIssueType] {
        try await get("rest/api/3/issue/createmeta/\(projectKey)/issuetypes?maxResults=50",
                      as: CreateMetaIssueTypesResponse.self).issueTypes
    }

    func projectComponents(projectKey: String) async throws -> [ProjectComponentDTO] {
        try await get("rest/api/3/project/\(projectKey)/components",
                      as: [ProjectComponentDTO].self)
    }

    func allFields() async throws -> [FieldDTO] {
        try await get("rest/api/3/field", as: [FieldDTO].self)
    }

    /// Team-Vorschläge über die JQL-Autocomplete-API (das Team-Feld hat keine
    /// createmeta-allowedValues; dieser Weg liefert ID + Name).
    func teamSuggestions(fieldName: String, query: String) async throws -> [JQLSuggestionsResponse.Result] {
        let field = fieldName.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? fieldName
        let value = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query
        return try await get(
            "rest/api/3/jql/autocompletedata/suggestions?fieldName=\(field)&fieldValue=\(value)",
            as: JQLSuggestionsResponse.self).results
    }

    /// Issue anlegen. Validierungsfehler (400) werden mit den Feld-Meldungen
    /// aus dem Body als `JiraError.api` durchgereicht.
    func createIssue(fields: [String: Any]) async throws -> CreatedIssueDTO {
        var request = try makeRequest("rest/api/3/issue")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["fields": fields])
        let (data, response) = try await Self.session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 400,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var messages = (json["errorMessages"] as? [String]) ?? []
            if let fieldErrors = json["errors"] as? [String: String] {
                messages += fieldErrors.map { "\($0.key): \($0.value)" }
            }
            if !messages.isEmpty {
                throw JiraError.api(message: messages.joined(separator: " · "))
            }
        }
        return try decode(CreatedIssueDTO.self, data: data, response: response)
    }

    // MARK: - Issue-Detail & Bearbeitung

    func issueDetail(key: String) async throws -> IssueDetailDTO {
        let fields = "summary,description,status,assignee,reporter,parent,issuelinks,attachment,issuetype,project,updated,components,labels,fixVersions"
        return try await get("rest/api/3/issue/\(key)?fields=\(fields)", as: IssueDetailDTO.self)
    }

    /// Felder eines Issues ändern (z. B. `{"summary": …}`, `{"description": <adf>}`,
    /// `{"parent": {"key": …}}`).
    func editIssue(key: String, fields: [String: Any]) async throws {
        try await sendNoContent(method: "PUT", path: "rest/api/3/issue/\(key)",
                                json: ["fields": fields])
    }

    /// Assignee setzen (`accountId = nil` ⇒ nicht zugewiesen).
    func assignIssue(key: String, accountId: String?) async throws {
        try await sendNoContent(method: "PUT", path: "rest/api/3/issue/\(key)/assignee",
                                json: ["accountId": accountId ?? NSNull()])
    }

    func projectVersions(projectKey: String) async throws -> [VersionDTO] {
        try await get("rest/api/3/project/\(projectKey)/versions", as: [VersionDTO].self)
    }

    func allLabels(maxResults: Int = 1000) async throws -> [String] {
        try await get("rest/api/3/label?maxResults=\(maxResults)", as: LabelsResponse.self).values
    }

    // MARK: - Personen

    /// Alle für ein Issue zuweisbaren Personen (fürs Assignee-Dropdown).
    func assignableUsers(issueKey: String, maxResults: Int = 200) async throws -> [UserDTO] {
        try await get("rest/api/3/user/assignable/search?issueKey=\(issueKey)&maxResults=\(maxResults)",
                      as: [UserDTO].self)
    }

    /// Alle Nutzer der Site — wird einmalig vorgeladen (kleines Team), damit
    /// Mentions/Zuweisungen ohne Server-Roundtrip vorgeschlagen werden können.
    func allUsers(maxResults: Int = 300) async throws -> [UserDTO] {
        try await get("rest/api/3/users/search?maxResults=\(maxResults)", as: [UserDTO].self)
    }

    // MARK: - Issue-Suche (Picker)

    /// Schnelle Issue-Vorschläge (Historie + Volltext) fürs Suchfeld und die
    /// Parent-/Link-Auswahl.
    func issuePicker(query: String) async throws -> [IssuePickerResponse.Suggestion] {
        let escaped = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let response: IssuePickerResponse = try await get(
            "rest/api/3/issue/picker?query=\(escaped)&showSubTasks=true&showSubTaskParent=true",
            as: IssuePickerResponse.self)
        return response.allSuggestions
    }

    /// Volltextsuche als Fallback, wenn der Picker nichts liefert
    /// (`text ~` durchsucht Summary, Beschreibung und Kommentare).
    func searchIssuesByText(_ text: String, maxResults: Int = 8) async throws -> [IssuePickerResponse.Suggestion] {
        let sanitized = text.replacingOccurrences(of: "\"", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return [] }
        let body: [String: Any] = [
            "jql": "text ~ \"\(sanitized)*\" ORDER BY updated DESC",
            "maxResults": maxResults,
            "fields": ["summary"],
        ]
        let response: BoardIssuesResponse = try await post("rest/api/3/search/jql",
                                                           json: body,
                                                           as: BoardIssuesResponse.self)
        return response.issues.map {
            IssuePickerResponse.Suggestion(id: Int($0.id), key: $0.key,
                                           summaryText: $0.fields.summary)
        }
    }

    // MARK: - Issue-Links

    func issueLinkTypes() async throws -> [IssueLinkTypeDTO] {
        try await get("rest/api/3/issueLinkType", as: IssueLinkTypesResponse.self).issueLinkTypes
    }

    /// Verknüpfung anlegen. **Achtung, kontraintuitiv:** Die `inward`-Seite ist
    /// die *aktive*. Für den Typ „Blocks" (`outward` = "blocks",
    /// `inward` = "is blocked by") gilt:
    ///
    ///     inwardKey = A, outwardKey = B   ⇒   „A blocks B" / „B is blocked by A"
    ///
    /// Live gegen eine Jira-Cloud-Instanz verifiziert: Bei einer
    /// bestehenden Verknüpfung ONE-9803 → ONE-9804 liefert GET auf ONE-9803 den
    /// Partner unter `outwardIssue` (Anzeige „blocks"), GET auf ONE-9804 unter
    /// `inwardIssue` (Anzeige „is blocked by") — das Link-Objekt ist also
    /// `{inward: 9803, outward: 9804}` und bedeutet „9803 blockt 9804".
    /// POST benutzt dieselben Rollen wie GET.
    func createIssueLink(typeName: String, inwardKey: String, outwardKey: String) async throws {
        try await sendNoContent(method: "POST", path: "rest/api/3/issueLink", json: [
            "type": ["name": typeName],
            "inwardIssue": ["key": inwardKey],
            "outwardIssue": ["key": outwardKey],
        ])
    }

    func deleteIssueLink(id: String) async throws {
        try await sendNoContent(method: "DELETE", path: "rest/api/3/issueLink/\(id)", json: nil)
    }

    // MARK: - Attachments

    /// Lädt Dateien als Anhänge hoch (multipart/form-data).
    func uploadAttachments(issueKey: String,
                           files: [(filename: String, mimeType: String, data: Data)]) async throws -> [AttachmentDTO] {
        var request = try makeRequest("rest/api/3/issue/\(issueKey)/attachments")
        request.httpMethod = "POST"
        request.setValue("no-check", forHTTPHeaderField: "X-Atlassian-Token")
        let boundary = "iJIRA-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        for file in files {
            body.append(Data("--\(boundary)\r\n".utf8))
            let disposition = "Content-Disposition: form-data; name=\"file\"; filename=\"\(file.filename)\"\r\n"
            body.append(Data(disposition.utf8))
            body.append(Data("Content-Type: \(file.mimeType)\r\n\r\n".utf8))
            body.append(file.data)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let (data, response) = try await Self.mediaSession.data(for: request)
        return try decode(AttachmentUploadResponse.self, data: data, response: response)
    }

    /// Rohdaten mit Authentifizierung laden (Attachment-Inhalte/-Thumbnails).
    /// Der Attachment-Endpoint redirectet auf eine signierte Media-URL —
    /// URLSession folgt automatisch.
    func fetchData(from urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw JiraError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        let (data, response) = try await Self.mediaSession.data(for: request)
        try validate(response)
        return data
    }

    /// Media-Services-UUID eines Anhangs — die ID, die ADF-`media`-Knoten
    /// referenzieren (≠ Attachment-ID). Sie steht in keiner REST-Antwort,
    /// aber der Content-Endpoint redirectet auf `…/file/<uuid>/binary`:
    /// Redirect unterdrücken und die UUID aus dem Location-Header lesen.
    /// Best effort — bei nil fällt der Aufrufer auf einen Link zurück.
    func mediaUUID(forAttachmentId id: String) async -> String? {
        guard var request = try? makeRequest("rest/api/3/attachment/content/\(id)") else { return nil }
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await Self.session.data(for: request,
                                                               delegate: NoRedirectDelegate()),
              let http = response as? HTTPURLResponse,
              (300..<400).contains(http.statusCode),
              let location = http.value(forHTTPHeaderField: "Location"),
              let range = location.range(of: "/file/")
        else { return nil }
        let uuid = location[range.upperBound...].prefix(while: { $0 != "/" && $0 != "?" })
        return uuid.isEmpty ? nil : String(uuid)
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

    /// Request, dessen Antwort-Body uninteressant ist (PUT/DELETE liefern 204):
    /// nur der Status wird geprüft.
    private func sendNoContent(method: String, path: String, json: [String: Any]?) async throws {
        var request = try makeRequest(path)
        request.httpMethod = method
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (_, response) = try await Self.session.data(for: request)
        try validate(response)
    }

    private func decode<T: Decodable>(_ type: T.Type, data: Data, response: URLResponse) throws -> T {
        try validate(response)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw JiraError.decoding
        }
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw JiraError.invalidResponse }
        switch http.statusCode {
        case 200..<300:
            return
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

/// Lässt URLSession dem Redirect NICHT folgen, damit die 3xx-Antwort samt
/// Location-Header beim Aufrufer ankommt (Media-UUID-Ermittlung).
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

enum JiraError: Error {
    case invalidResponse
    case decoding
    case unauthorized
    case notFound
    case rateLimited(retryAfter: TimeInterval?)
    case http(status: Int)
    /// Validierungs-/Fachfehler mit Meldung aus dem Response-Body.
    case api(message: String)

    var userMessage: String {
        switch self {
        case .api(let message):
            return message
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
