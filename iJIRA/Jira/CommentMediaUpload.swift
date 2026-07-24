import Foundation
import UniformTypeIdentifiers

/// Drop-Upload für die Kommentar-Composer: Dateien als Anhänge hochladen und
/// Markdown-Tokens für den Entwurf bauen. `![name](media:uuid)` wird beim
/// Senden zum eingebetteten ADF-Media-Knoten (Bild/Video inline im Kommentar);
/// ohne ermittelbare Media-UUID fällt das Token auf einen Anhang-Link zurück.
enum CommentMediaUpload {
    /// Liest lokale Datei-URLs ein (nicht Lesbares wird übersprungen).
    static func readFiles(_ urls: [URL]) -> [(filename: String, mimeType: String, data: Data)] {
        urls.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            return (url.lastPathComponent, mime, data)
        }
    }

    /// Upload + Token-Bau. Wirft bei Upload-Fehlern; waren alle Dateien
    /// unlesbar, kommt ein leeres Array zurück.
    static func uploadTokens(client: JiraClient, issueKey: String, urls: [URL]) async throws -> [String] {
        let files = readFiles(urls)
        guard !files.isEmpty else { return [] }
        let uploaded = try await client.uploadAttachments(issueKey: issueKey, files: files)

        var tokens: [String] = []
        for attachment in uploaded {
            // Alt-Text = Dateiname (darüber ordnet auch iJIRAs Renderer den
            // Anhang zu); eckige Klammern würden das Token zerbrechen.
            let name = attachment.filename
                .replacingOccurrences(of: "[", with: "(")
                .replacingOccurrences(of: "]", with: ")")
            if let uuid = await client.mediaUUID(forAttachmentId: attachment.id) {
                tokens.append("![\(name)](media:\(uuid))")
            } else {
                tokens.append("[\(name)](\(attachment.content))")
            }
        }
        return tokens
    }

    /// Tokens ans Entwurfs-Ende anhängen — jedes auf eigener Zeile, damit
    /// der Markdown-Parser sie als Blöcke erkennt.
    static func appending(_ tokens: [String], to draft: String) -> String {
        let joined = tokens.joined(separator: "\n") + "\n"
        if draft.isEmpty { return joined }
        return draft + (draft.hasSuffix("\n") ? "" : "\n") + joined
    }
}
