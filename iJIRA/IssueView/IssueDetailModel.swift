import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// Zustand + Operationen eines Issue-Detail-Fensters: Laden, Feld-Edits,
/// Kommentare, Attachments (inkl. Thumbnail-Cache und Uploads).
@MainActor
@Observable
final class IssueDetailModel {
    let issueKey: String
    private let appState: AppState
    let directory: UserDirectory

    private(set) var detail: IssueDetailDTO?
    private(set) var comments: [CommentDTO] = []
    private(set) var isLoading = false
    private(set) var loadError: String?

    /// Für ein Issue zuweisbare Personen (vorab geladen fürs Dropdown).
    private(set) var assignableUsers: [UserDTO] = []

    /// Verfügbare Link-Typen (lazy beim ersten „Verknüpfung hinzufügen").
    private(set) var linkTypes: [IssueLinkTypeDTO] = []

    /// Mögliche Workflow-Übergänge — fürs Status-Dropdown im Header.
    private(set) var availableTransitions: [TransitionDTO] = []

    /// Team des Issues (Atlassian-Team-Custom-Field, Name via Raw-Fetch).
    private(set) var teamName: String?

    /// Thumbnail-Cache: Attachment-ID → Bild. Einträge entstehen lazy über
    /// `thumbnail(for:)`.
    private(set) var thumbnails: [String: NSImage] = [:]
    private var thumbnailLoadsInFlight: Set<String> = []

    /// IDs von Attachments, die gerade heruntergeladen/geöffnet werden.
    private(set) var openingAttachments: Set<String> = []
    private(set) var isUploading = false

    /// Fehlermeldung der letzten Aktion (Edit/Upload/Kommentar) — für die UI.
    var actionError: String?

    /// Harvest: bislang von mir auf dieses Issue geloggte Stunden
    /// (nil = unbekannt/lädt noch).
    private(set) var loggedHours: Double?
    private var loggedTimeFetchedAt: Date?
    private(set) var isLoggingTime = false

    init(issueKey: String, appState: AppState, directory: UserDirectory) {
        self.issueKey = issueKey
        self.appState = appState
        self.directory = directory
    }

    var client: JiraClient? { appState.currentClient() }
    var myAccountId: String? { appState.accountId }
    var siteBaseURL: URL? { appState.siteBaseURL }
    var attachments: [AttachmentDTO] { detail?.fields.attachment ?? [] }
    var webURL: URL? { URL(string: appState.issueWebURL(issueKey)) }

    // MARK: - Laden

    func load() async {
        guard let client else {
            loadError = "Nicht mit Jira verbunden."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            async let detailTask = client.issueDetail(key: issueKey)
            async let commentsTask = client.allComments(issueKey: issueKey)
            detail = try await detailTask
            comments = try await commentsTask
            loadError = nil
            Log.app.info("Issue \(self.issueKey, privacy: .public) geladen: \(self.comments.count) Kommentare, \(self.attachments.count) Anhänge, \(self.detail?.fields.issuelinks?.count ?? 0) Links")
            // Harvest-Summe parallel nachziehen (non-blocking, Nice-to-have).
            Task { await self.refreshLoggedTime() }
            // Projekt/Typ/Team/Komponenten als „zuletzt angesehen"-Vorbelegung
            // übernehmen; liefert nebenbei den Team-Namen für die Details.
            Task {
                self.teamName = await CreateIssueService.shared.captureViewedIssue(key: self.issueKey)
            }
            // Zuweisbare Personen im Hintergrund vorladen (fürs Dropdown).
            if assignableUsers.isEmpty {
                assignableUsers = (try? await client.assignableUsers(issueKey: issueKey)) ?? []
            }
            availableTransitions = (try? await client.transitions(issueKey: issueKey)) ?? []
        } catch {
            loadError = (error as? JiraError)?.userMessage ?? error.localizedDescription
        }
    }

    /// Detail neu laden, ohne die UI zurückzusetzen (nach Edits).
    func refresh() async {
        guard let client else { return }
        do {
            detail = try await client.issueDetail(key: issueKey)
            comments = (try? await client.allComments(issueKey: issueKey)) ?? comments
            availableTransitions = (try? await client.transitions(issueKey: issueKey))
                ?? availableTransitions
        } catch {
            actionError = (error as? JiraError)?.userMessage ?? error.localizedDescription
        }
    }

    /// Statuswechsel direkt aus der Detailview (Dropdown am Status-Badge).
    func applyTransition(_ transition: TransitionDTO) async -> Bool {
        let success = await performEdit { client in
            try await client.applyTransition(issueKey: self.issueKey,
                                             transitionId: transition.id)
        }
        if success {
            Log.app.info("Transition \(self.issueKey, privacy: .public) → \(transition.to?.name ?? transition.name ?? "?", privacy: .public)")
            // Board-Snapshot zieht nach, damit die Karte gleich umzieht.
            MainWindowController.shared?.boardStore.kickRefresh()
        }
        return success
    }

    // MARK: - Feld-Edits

    func saveSummary(_ summary: String) async -> Bool {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return await performEdit { client in
            try await client.editIssue(key: self.issueKey, fields: ["summary": trimmed])
        }
    }

    /// Beschreibung als editierbares Markdown (plus die Blöcke, die Markdown
    /// nicht abbilden kann — sie werden beim Speichern wieder angehängt).
    func descriptionConversion() -> ADFMarkdownConversion {
        guard let description = detail?.fields.description else {
            return ADFMarkdownConversion(markdown: "", preservedNodes: [])
        }
        return adfToMarkdown(description, siteBase: siteBaseURL)
    }

    func saveDescription(markdown: String, preservedNodes: [[String: Any]]) async -> Bool {
        var doc = markdownToADFDoc(markdown, siteBaseURL: siteBaseURL)
        if !preservedNodes.isEmpty {
            var content = doc["content"] as? [[String: Any]] ?? []
            content += preservedNodes
            doc["content"] = content
        }
        return await performEdit { client in
            try await client.editIssue(key: self.issueKey, fields: ["description": doc])
        }
    }

    func loadLinkTypes() async {
        guard linkTypes.isEmpty, let client else { return }
        linkTypes = (try? await client.issueLinkTypes()) ?? []
    }

    func setAssignee(_ user: UserDTO?) async -> Bool {
        await performEdit { client in
            try await client.assignIssue(key: self.issueKey, accountId: user?.accountId)
        }
    }

    func setParent(key parentKey: String?) async -> Bool {
        await performEdit { client in
            let value: Any = parentKey.map { ["key": $0] as [String: Any] } ?? NSNull()
            try await client.editIssue(key: self.issueKey, fields: ["parent": value])
        }
    }

    func addLink(typeName: String, direction: LinkDirection, otherKey: String) async -> Bool {
        await performEdit { client in
            switch direction {
            case .outward:
                try await client.createIssueLink(typeName: typeName,
                                                 inwardKey: otherKey, outwardKey: self.issueKey)
            case .inward:
                try await client.createIssueLink(typeName: typeName,
                                                 inwardKey: self.issueKey, outwardKey: otherKey)
            }
        }
    }

    func removeLink(id: String) async -> Bool {
        await performEdit { client in
            try await client.deleteIssueLink(id: id)
        }
    }

    enum LinkDirection { case inward, outward }

    /// Gemeinsames Muster aller Edits: ausführen, bei Erfolg still neu laden.
    private func performEdit(_ operation: (JiraClient) async throws -> Void) async -> Bool {
        guard let client else {
            actionError = "Nicht mit Jira verbunden."
            return false
        }
        actionError = nil
        do {
            try await operation(client)
            await refresh()
            return true
        } catch {
            actionError = (error as? JiraError)?.userMessage ?? error.localizedDescription
            return false
        }
    }

    // MARK: - Kommentare

    func addComment(markdown: String) async -> Bool {
        guard let client else {
            actionError = "Nicht mit Jira verbunden."
            return false
        }
        actionError = nil
        do {
            let body = markdownToADFBody(markdown, siteBaseURL: siteBaseURL)
            let comment = try await client.addComment(issueKey: issueKey, adfBody: body)
            comments.append(comment)
            return true
        } catch {
            actionError = (error as? JiraError)?.userMessage ?? error.localizedDescription
            return false
        }
    }

    // MARK: - Harvest-Zeiterfassung

    /// Summe meiner Harvest-Einträge zu diesem Issue. Zählt Einträge mit
    /// passender `external_reference` (von iJIRA/offiziellem Plugin) UND
    /// solche, deren Notes den Jira-Key enthalten — damit auch direkt in
    /// Harvest erfasste Zeit erscheint. 5-min-Cache (geteilt in HarvestState).
    func refreshLoggedTime(force: Bool = false) async {
        guard let harvest = HarvestState.shared, harvest.isConfigured,
              let issueId = detail?.id else { return }
        if !force, let fetchedAt = loggedTimeFetchedAt,
           Date().timeIntervalSince(fetchedAt) < 300 { return }
        guard let entries = await harvest.timeEntries(force: force) else { return }

        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: issueKey) + "\\b"
        let keyRegex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        loggedHours = entries.filter { entry in
            if entry.externalReference?.id == issueId { return true }
            guard let notes = entry.notes, let keyRegex else { return false }
            let range = NSRange(notes.startIndex..., in: notes)
            return keyRegex.firstMatch(in: notes, range: range) != nil
        }.reduce(0) { $0 + ($1.hours ?? 0) }
        loggedTimeFetchedAt = Date()
        Log.app.info("Harvest: \(self.issueKey, privacy: .public) — \(self.loggedHours ?? 0, format: .fixed(precision: 2)) h geloggt")
    }

    /// Loggt `hours` auf das fest konfigurierte Harvest-Projekt/-Task.
    /// Notes = "KEY: Titel", verlinkt über external_reference.permalink.
    func logTime(hours: Double) async -> Bool {
        guard let harvest = HarvestState.shared, harvest.isConfigured,
              let harvestClient = harvest.client(),
              let projectId = harvest.projectId, let taskId = harvest.taskId,
              let detail else {
            actionError = "Harvest ist nicht vollständig konfiguriert."
            return false
        }
        isLoggingTime = true
        defer { isLoggingTime = false }
        actionError = nil

        // Der Arbeitstag zählt in Europe/Berlin — egal, wo der Mac steht.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/Berlin")
        formatter.dateFormat = "yyyy-MM-dd"
        let spentDate = formatter.string(from: Date())

        let projectKey = issueKey.components(separatedBy: "-").first ?? issueKey
        let notes = "\(issueKey): \(String(detail.fields.summary.prefix(200)))"
        var reference = ["id": detail.id, "group_id": projectKey]
        if let webURL { reference["permalink"] = webURL.absoluteString }

        do {
            let entry = try await harvestClient.createTimeEntry(
                projectId: projectId, taskId: taskId,
                spentDate: spentDate, hours: hours,
                notes: notes, externalReference: reference)
            harvest.noteLoggedEntry(entry)
            loggedHours = (loggedHours ?? 0) + hours
            Log.app.info("Harvest: \(hours, format: .fixed(precision: 2)) h auf \(self.issueKey, privacy: .public) geloggt")
            return true
        } catch {
            actionError = (error as? HarvestError)?.userMessage ?? error.localizedDescription
            return false
        }
    }

    // MARK: - Attachments

    /// Attachment zu einem ADF-Media-Knoten (Zuordnung über den alt-Text =
    /// Dateiname; die Media-UUID taucht in der REST-Antwort nicht auf).
    func attachment(forMediaAlt alt: String?) -> AttachmentDTO? {
        guard let alt, !alt.isEmpty else { return nil }
        return attachments.first { $0.filename == alt }
    }

    /// Thumbnail liefern bzw. Laden anstoßen (Ergebnis landet observable in
    /// `thumbnails`, die View aktualisiert sich von selbst).
    func thumbnail(for attachment: AttachmentDTO) -> NSImage? {
        if let image = thumbnails[attachment.id] { return image }
        guard !thumbnailLoadsInFlight.contains(attachment.id),
              let client,
              let urlString = attachment.thumbnail ?? (attachment.isImage ? attachment.content : nil)
        else { return nil }
        thumbnailLoadsInFlight.insert(attachment.id)
        Task {
            if let data = try? await client.fetchData(from: urlString),
               let image = NSImage(data: data) {
                thumbnails[attachment.id] = image
            }
        }
        return nil
    }

    /// Lädt den Anhang in ein Temp-Verzeichnis und öffnet ihn mit der
    /// Standard-App (Preview, QuickTime, …).
    func openAttachment(_ attachment: AttachmentDTO) {
        guard let client, !openingAttachments.contains(attachment.id) else { return }
        openingAttachments.insert(attachment.id)
        Task {
            defer { openingAttachments.remove(attachment.id) }
            do {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("iJIRA-Anhaenge", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let file = dir.appendingPathComponent("\(attachment.id)-\(attachment.filename)")
                if !FileManager.default.fileExists(atPath: file.path) {
                    let data = try await client.fetchData(from: attachment.content)
                    try data.write(to: file)
                }
                NSWorkspace.shared.open(file)
            } catch {
                actionError = "Anhang \(attachment.filename) konnte nicht geladen werden."
            }
        }
    }

    /// Dateien (Drag & Drop) als Anhänge hochladen.
    func uploadFiles(_ urls: [URL]) async {
        guard let client, !urls.isEmpty else { return }
        isUploading = true
        defer { isUploading = false }
        actionError = nil

        var files: [(filename: String, mimeType: String, data: Data)] = []
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            files.append((url.lastPathComponent, mime, data))
        }
        guard !files.isEmpty else {
            actionError = "Keine lesbaren Dateien im Drop."
            return
        }
        do {
            _ = try await client.uploadAttachments(issueKey: issueKey, files: files)
            await refresh()
        } catch {
            actionError = (error as? JiraError)?.userMessage ?? "Upload fehlgeschlagen."
        }
    }
}
