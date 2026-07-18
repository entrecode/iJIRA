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

    /// Thumbnail-Cache: Attachment-ID → Bild. Einträge entstehen lazy über
    /// `thumbnail(for:)`.
    private(set) var thumbnails: [String: NSImage] = [:]
    private var thumbnailLoadsInFlight: Set<String> = []

    /// IDs von Attachments, die gerade heruntergeladen/geöffnet werden.
    private(set) var openingAttachments: Set<String> = []
    private(set) var isUploading = false

    /// Fehlermeldung der letzten Aktion (Edit/Upload/Kommentar) — für die UI.
    var actionError: String?

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
            // Zuweisbare Personen im Hintergrund vorladen (fürs Dropdown).
            if assignableUsers.isEmpty {
                assignableUsers = (try? await client.assignableUsers(issueKey: issueKey)) ?? []
            }
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
        } catch {
            actionError = (error as? JiraError)?.userMessage ?? error.localizedDescription
        }
    }

    // MARK: - Feld-Edits

    func saveSummary(_ summary: String) async -> Bool {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return await performEdit { client in
            try await client.editIssue(key: self.issueKey, fields: ["summary": trimmed])
        }
    }

    func saveDescription(adf: [String: Any]) async -> Bool {
        await performEdit { client in
            try await client.editIssue(key: self.issueKey, fields: ["description": adf])
        }
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
