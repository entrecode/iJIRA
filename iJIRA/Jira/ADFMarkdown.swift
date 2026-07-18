import Foundation

/// Rückrichtung zu `markdownToADFDoc`: wandelt ein ADF-Dokument in unser
/// Markdown-Subset, damit Beschreibungen im selben Editor bearbeitet werden
/// können wie Kommentare.
///
/// Nicht als Markdown darstellbare Blöcke (Media/Anhänge, Tabellen, Expands)
/// werden nicht verworfen, sondern als Original-Knoten zurückgegeben — beim
/// Speichern hängt der Aufrufer sie wieder ans Dokument an. Textinhalte
/// round-trippen damit verlustfrei, Spezialblöcke überleben (rücken aber ans
/// Ende).
struct ADFMarkdownConversion {
    let markdown: String
    /// Original-Knoten, die Markdown nicht abbilden kann (JSON-Dictionaries,
    /// direkt wieder in den content einsetzbar).
    let preservedNodes: [[String: Any]]
    /// Menschenlesbare Beschreibung der erhaltenen Blöcke ("2 Anhänge, 1 Tabelle").
    var preservedSummary: String? {
        guard !preservedNodes.isEmpty else { return nil }
        var media = 0, other = 0
        for node in preservedNodes {
            let type = node["type"] as? String
            if type == "mediaSingle" || type == "mediaGroup" || type == "media" { media += 1 }
            else { other += 1 }
        }
        var parts: [String] = []
        if media > 0 { parts.append("\(media) Anhang-Block\(media > 1 ? "s" : "")") }
        if other > 0 { parts.append("\(other) Spezial-Block\(other > 1 ? "s" : "") (Tabelle o. Ä.)") }
        return parts.joined(separator: ", ")
    }
}

func adfToMarkdown(_ document: ADFNode, siteBase: URL?) -> ADFMarkdownConversion {
    var lines: [String] = []
    var preserved: [[String: Any]] = []

    for node in document.content ?? [] {
        convertBlock(node, siteBase: siteBase, into: &lines, preserved: &preserved)
    }

    // Doppelte Leerzeilen am Ende vermeiden.
    while lines.last?.isEmpty == true { lines.removeLast() }
    return ADFMarkdownConversion(markdown: lines.joined(separator: "\n"),
                                 preservedNodes: preserved)
}

// MARK: - Blöcke

private func convertBlock(_ node: ADFNode, siteBase: URL?,
                          into lines: inout [String], preserved: inout [[String: Any]]) {
    switch node.type {
    case "paragraph":
        lines.append(inlineMarkdown(node.content ?? [], siteBase: siteBase))
        lines.append("")

    case "heading":
        let level = min(max(node.attrs?.level ?? 1, 1), 6)
        lines.append(String(repeating: "#", count: level) + " "
                     + inlineMarkdown(node.content ?? [], siteBase: siteBase))
        lines.append("")

    case "codeBlock":
        let lang = node.attrs?.language ?? ""
        let code = node.content?.map { $0.plainText() }.joined(separator: "\n") ?? ""
        lines.append("```" + lang)
        lines.append(contentsOf: code.components(separatedBy: "\n"))
        lines.append("```")
        lines.append("")

    case "bulletList", "orderedList":
        let ordered = node.type == "orderedList"
        for (index, item) in (node.content ?? []).enumerated() {
            let marker = ordered ? "\(index + 1). " : "- "
            lines.append(marker + listItemText(item, siteBase: siteBase, preserved: &preserved))
        }
        lines.append("")

    case "blockquote":
        var inner: [String] = []
        for child in node.content ?? [] {
            convertBlock(child, siteBase: siteBase, into: &inner, preserved: &preserved)
        }
        while inner.last?.isEmpty == true { inner.removeLast() }
        lines.append(contentsOf: inner.map { $0.isEmpty ? ">" : "> " + $0 })
        lines.append("")

    case "rule":
        lines.append("---")
        lines.append("")

    case "mediaSingle", "mediaGroup", "media", "table", "expand", "extension",
         "bodiedExtension", "layoutSection", "panel", "decisionList", "taskList":
        if let dict = node.jsonDictionary() {
            preserved.append(dict)
        }

    default:
        // Unbekannte Container: Text extrahieren statt Inhalt zu verlieren.
        if let content = node.content, !content.isEmpty {
            for child in content {
                convertBlock(child, siteBase: siteBase, into: &lines, preserved: &preserved)
            }
        } else if let dict = node.jsonDictionary() {
            preserved.append(dict)
        }
    }
}

/// listItem → einzeiliger Markdown-Text (verschachtelte Blöcke werden flach angehängt).
private func listItemText(_ item: ADFNode, siteBase: URL?,
                          preserved: inout [[String: Any]]) -> String {
    var parts: [String] = []
    for child in item.content ?? [] {
        switch child.type {
        case "paragraph":
            parts.append(inlineMarkdown(child.content ?? [], siteBase: siteBase))
        case "bulletList", "orderedList":
            // Verschachtelte Listen werden flach angehängt (Subset-Grenze).
            for (index, nested) in (child.content ?? []).enumerated() {
                let marker = child.type == "orderedList" ? "\(index + 1). " : "- "
                parts.append(marker + listItemText(nested, siteBase: siteBase, preserved: &preserved))
            }
        default:
            if let dict = child.jsonDictionary() { preserved.append(dict) }
        }
    }
    return parts.joined(separator: " ")
}

// MARK: - Inline

private func inlineMarkdown(_ nodes: [ADFNode], siteBase: URL?) -> String {
    var out = ""
    for node in nodes {
        switch node.type {
        case "text":
            out += markedText(node)
        case "mention":
            let name = (node.attrs?.text ?? "@?").trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            if let id = node.attrs?.id {
                out += "@[\(name)](\(id))"
            } else {
                out += "@" + name
            }
        case "emoji":
            out += node.attrs?.text ?? node.attrs?.shortName ?? ""
        case "hardBreak":
            out += "\n"
        case "inlineCard":
            if let url = node.attrs?.url {
                // Browse-Link derselben Site → nackter Key (wird beim Parsen
                // wieder zur Ticket-Karte), sonst URL.
                if let siteBase, url.hasPrefix(siteBase.absoluteString),
                   let key = JiraKeyParser.key(from: url) {
                    out += key
                } else {
                    out += url
                }
            }
        case "status":
            out += node.attrs?.text ?? ""
        default:
            out += inlineMarkdown(node.content ?? [], siteBase: siteBase)
        }
    }
    return out
}

private func markedText(_ node: ADFNode) -> String {
    var text = node.text ?? ""
    var isBold = false, isItalic = false, isCode = false
    var linkHref: String?
    for mark in node.marks ?? [] {
        switch mark.type {
        case "strong": isBold = true
        case "em": isItalic = true
        case "code": isCode = true
        case "link": linkHref = mark.attrs?.href ?? mark.attrs?.url
        default: break
        }
    }
    if isCode { return "`\(text)`" }
    if isBold { text = "**\(text)**" }
    else if isItalic { text = "*\(text)*" }
    if let linkHref {
        return linkHref == text ? linkHref : "[\(text)](\(linkHref))"
    }
    return text
}

// MARK: - Helpers

extension ADFNode {
    /// Knoten als JSON-Dictionary (für Request-Bodies / Erhalt beim Editieren).
    func jsonDictionary() -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
