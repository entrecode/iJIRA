import Foundation

/// Rückrichtung zu `markdownToADFDoc`: wandelt ein ADF-Dokument in unser
/// Markdown-Subset, damit Beschreibungen im selben Editor bearbeitet werden
/// können wie Kommentare.
///
/// Nicht als Markdown darstellbare Blöcke (Media/Anhänge, Panels, Expands,
/// Tabellen mit verbundenen Zellen o. Ä.) werden nicht verworfen, sondern als
/// Original-Knoten zurückgegeben — beim Speichern hängt der Aufrufer sie
/// wieder ans Dokument an. Textinhalte round-trippen damit verlustfrei,
/// Spezialblöcke überleben (rücken aber ans Ende).
struct ADFMarkdownConversion {
    let markdown: String
    /// Original-Knoten, die Markdown nicht abbilden kann (JSON-Dictionaries,
    /// direkt wieder in den content einsetzbar).
    let preservedNodes: [[String: Any]]
    /// Menschenlesbare Beschreibung der erhaltenen Blöcke ("2 Anhänge, 1 Tabelle").
    var preservedSummary: String? {
        guard !preservedNodes.isEmpty else { return nil }
        var media = 0, tables = 0, other = 0
        for node in preservedNodes {
            let type = node["type"] as? String
            if type == "mediaSingle" || type == "mediaGroup" || type == "media" { media += 1 }
            else if type == "table" { tables += 1 }
            else { other += 1 }
        }
        var parts: [String] = []
        if media > 0 { parts.append("\(media) Anhang-Block\(media > 1 ? "s" : "")") }
        if tables > 0 { parts.append("\(tables) Tabelle\(tables > 1 ? "n" : "") mit verbundenen Zellen o. Ä.") }
        if other > 0 { parts.append("\(other) Spezial-Block\(other > 1 ? "s" : "") (Panel o. Ä.)") }
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
        let text = inlineMarkdown(node.content ?? [], siteBase: siteBase)
        lines.append(contentsOf: text.components(separatedBy: "\n").map(escapeLineStart))
        lines.append("")

    case "heading":
        let level = min(max(node.attrs?.level ?? 1, 1), 6)
        // hardBreaks in Überschriften kann Markdown nicht — zu Leerzeichen.
        let text = inlineMarkdown(node.content ?? [], siteBase: siteBase)
            .replacingOccurrences(of: "\n", with: " ")
        lines.append(String(repeating: "#", count: level) + " " + text)
        lines.append("")

    case "codeBlock":
        let lang = node.attrs?.language ?? ""
        let code = node.content?.map { $0.plainText() }.joined(separator: "\n") ?? ""
        // Enthält der Code selbst ```, wird mit ~~~ eingezäunt.
        let fence = code.contains("```") ? "~~~" : "```"
        lines.append(fence + lang)
        lines.append(contentsOf: code.components(separatedBy: "\n"))
        lines.append(fence)
        lines.append("")

    case "bulletList", "orderedList", "taskList":
        lines.append(contentsOf: listLines(node, indent: 0, siteBase: siteBase, preserved: &preserved))
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

    case "table":
        if let table = tableMarkdown(node, siteBase: siteBase) {
            lines.append(contentsOf: table)
            lines.append("")
        } else if let dict = node.jsonDictionary() {
            preserved.append(dict)
        }

    case "mediaSingle", "mediaGroup", "media", "expand", "extension",
         "bodiedExtension", "layoutSection", "panel", "decisionList":
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

// MARK: Listen

/// Liste → Markdown-Zeilen. Unterlisten werden um die Breite des Markers
/// eingerückt, weitere Absätze/hardBreaks eines Punkts als eingerückte
/// Fortsetzungszeilen geschrieben (beim Parsen: hardBreaks im selben Punkt).
private func listLines(_ list: ADFNode, indent: Int, siteBase: URL?,
                       preserved: inout [[String: Any]]) -> [String] {
    let pad = String(repeating: " ", count: indent)
    var out: [String] = []

    /// Text eines Punkts: erste Zeile mit Marker, Rest als Fortsetzung.
    func appendItem(marker: String, text: String, isFirst: Bool) {
        let continuation = pad + String(repeating: " ", count: marker.count)
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            if index == 0 && isFirst {
                out.append(pad + marker + line)
            } else {
                out.append(continuation + escapeLineStart(line))
            }
        }
    }

    if list.type == "taskList" {
        for child in list.content ?? [] {
            if child.type == "taskList" {
                out += listLines(child, indent: indent + 2, siteBase: siteBase, preserved: &preserved)
            } else {
                let marker = child.attrs?.state == "DONE" ? "- [x] " : "- [ ] "
                appendItem(marker: marker,
                           text: inlineMarkdown(child.content ?? [], siteBase: siteBase),
                           isFirst: true)
            }
        }
        return out
    }

    let ordered = list.type == "orderedList"
    let start = list.attrs?.order ?? 1
    for (index, item) in (list.content ?? []).enumerated() {
        let marker = ordered ? "\(start + index). " : "- "
        var wroteText = false
        for child in item.content ?? [] {
            switch child.type {
            case "paragraph":
                appendItem(marker: marker,
                           text: inlineMarkdown(child.content ?? [], siteBase: siteBase),
                           isFirst: !wroteText)
                wroteText = true
            case "bulletList", "orderedList", "taskList":
                if !wroteText {
                    out.append(pad + marker)
                    wroteText = true
                }
                out += listLines(child, indent: indent + marker.count,
                                 siteBase: siteBase, preserved: &preserved)
            default:
                if let dict = child.jsonDictionary() { preserved.append(dict) }
            }
        }
        if !wroteText { out.append(pad + marker) }
    }
    return out
}

// MARK: Tabellen

/// Tabelle → GFM-Tabelle, sofern Markdown sie verlustarm abbilden kann:
/// rechteckig, keine verbundenen oder eingefärbten Zellen, nur Absätze in
/// den Zellen, Kopfzellen höchstens in der ersten Zeile. Sonst nil — dann
/// bleibt der Original-Knoten erhalten. Spaltenbreiten gehen verloren.
///
/// Eine Tabelle ohne Kopfzeile bekommt eine leere Kopfzeile, die der Parser
/// wieder weglässt (siehe `parseTable`).
private func tableMarkdown(_ table: ADFNode, siteBase: URL?) -> [String]? {
    guard table.attrs?.isNumberColumnEnabled != true else { return nil }
    let rows = table.content ?? []
    guard !rows.isEmpty, rows.allSatisfy({ $0.type == "tableRow" }) else { return nil }
    let grid = rows.map { $0.content ?? [] }
    let columns = grid[0].count
    guard columns > 0, grid.allSatisfy({ $0.count == columns }) else { return nil }

    for cell in grid.joined() {
        guard cell.type == "tableHeader" || cell.type == "tableCell",
              (cell.attrs?.colspan ?? 1) == 1, (cell.attrs?.rowspan ?? 1) == 1,
              cell.attrs?.background == nil,
              (cell.content ?? []).allSatisfy({ $0.type == "paragraph" }) else { return nil }
    }
    let hasHeader = grid[0].allSatisfy { $0.type == "tableHeader" }
    guard hasHeader || grid[0].allSatisfy({ $0.type == "tableCell" }),
          grid.dropFirst().joined().allSatisfy({ $0.type == "tableCell" }) else { return nil }

    func cellText(_ cell: ADFNode) -> String {
        (cell.content ?? [])
            .map { inlineMarkdown($0.content ?? [], siteBase: siteBase) }
            .joined(separator: "\n")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    var texts = grid.map { $0.map(cellText) }
    if !hasHeader { texts.insert(Array(repeating: "", count: columns), at: 0) }

    // Spalten auf gleiche Breite auffüllen — im (monospaced) Editor lesbar.
    let widths = (0..<columns).map { column in
        max(3, texts.map { $0[column].count }.max() ?? 0)
    }
    func line(_ cells: [String]) -> String {
        let padded = cells.enumerated().map { column, text in
            text + String(repeating: " ", count: widths[column] - text.count)
        }
        return "| " + padded.joined(separator: " | ") + " |"
    }

    var out = [line(texts[0])]
    out.append("| " + widths.map { String(repeating: "-", count: $0) }.joined(separator: " | ") + " |")
    out += texts.dropFirst().map(line)
    return out
}

// MARK: - Inline

private func inlineMarkdown(_ nodes: [ADFNode], siteBase: URL?) -> String {
    var out = ""
    for node in mergedTextRuns(nodes) {
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
            out += escapeInline(node.attrs?.text ?? "")
        default:
            out += inlineMarkdown(node.content ?? [], siteBase: siteBase)
        }
    }
    return out
}

/// Fasst benachbarte Textknoten mit gleichen Marks zusammen — sonst entstünde
/// aus „**a**" + „**b**" ein kaputtes `**a****b**`.
private func mergedTextRuns(_ nodes: [ADFNode]) -> [ADFNode] {
    var result: [ADFNode] = []
    for node in nodes {
        if node.type == "text", let last = result.last, last.type == "text",
           markSignature(last) == markSignature(node) {
            result[result.count - 1] = ADFNode(type: "text",
                                               text: (last.text ?? "") + (node.text ?? ""),
                                               content: nil, marks: last.marks, attrs: last.attrs)
        } else {
            result.append(node)
        }
    }
    return result
}

private func markSignature(_ node: ADFNode) -> String {
    (node.marks ?? [])
        .map { ($0.type ?? "") + ($0.attrs?.href ?? $0.attrs?.url ?? "") }
        .sorted()
        .joined(separator: "|")
}

private func markedText(_ node: ADFNode) -> String {
    let raw = node.text ?? ""
    var isBold = false, isItalic = false, isCode = false, isStrike = false
    var linkHref: String?
    for mark in node.marks ?? [] {
        switch mark.type {
        case "strong": isBold = true
        case "em": isItalic = true
        case "code": isCode = true
        case "strike": isStrike = true
        case "link": linkHref = mark.attrs?.href ?? mark.attrs?.url
        default: break
        }
    }

    if isCode {
        let code = codeSpan(raw)
        return linkHref.map { "[\(code)](\($0))" } ?? code
    }
    // Nackte URL bleibt nackt (und unescaped).
    if let linkHref, linkHref == raw, !isBold, !isItalic, !isStrike {
        return linkHref
    }

    // Leerzeichen an den Rändern gehören vor/hinter die Marker — „**fett **"
    // wäre kein gültiges Markdown mehr.
    let core = raw.trimmingCharacters(in: .whitespaces)
    guard !core.isEmpty else { return raw }
    let leading = String(raw.prefix(while: { $0 == " " }))
    let trailing = String(raw.reversed().prefix(while: { $0 == " " }))

    var text = escapeInline(core, inLinkLabel: linkHref != nil)
    if isBold && isItalic { text = "***\(text)***" }
    else if isBold { text = "**\(text)**" }
    else if isItalic { text = "*\(text)*" }
    if isStrike { text = "~~\(text)~~" }
    if let linkHref { text = "[\(text)](\(linkHref))" }
    return leading + text + trailing
}

/// Inline-Code mit so vielen Backticks, dass enthaltene Backticks nicht stören.
private func codeSpan(_ code: String) -> String {
    var longest = 0, current = 0
    for ch in code {
        current = ch == "`" ? current + 1 : 0
        longest = max(longest, current)
    }
    let fence = String(repeating: "`", count: longest + 1)
    let padded = code.hasPrefix("`") || code.hasSuffix("`") ? " \(code) " : code
    return fence + padded + fence
}

private let escapablePunctuation = Set("\\`*_{}[]()<>#+-.!|~")

/// Escaped Zeichen, die der Parser sonst als Formatierung lesen würde.
/// `_` nur an Wortgrenzen (snake_case bleibt lesbar), `~` nur doppelt,
/// `[` nur, wenn sonst ein Link entstünde (in Link-Texten `[` und `]` immer).
private func escapeInline(_ text: String, inLinkLabel: Bool = false) -> String {
    let chars = Array(text)
    let escapeBrackets = inLinkLabel || text.contains("](")
    var out = ""
    for (i, ch) in chars.enumerated() {
        let prev: Character? = i > 0 ? chars[i - 1] : nil
        let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
        let isWord: (Character?) -> Bool = { $0.map { $0.isLetter || $0.isNumber } ?? false }
        switch ch {
        case "\\":
            if let next, escapablePunctuation.contains(next) { out += "\\" }
        case "*", "`":
            out += "\\"
        case "_":
            if !(isWord(prev) && isWord(next)) { out += "\\" }
        case "~":
            if prev == "~" || next == "~" { out += "\\" }
        case "[":
            if escapeBrackets { out += "\\" }
        case "]":
            if inLinkLabel { out += "\\" }
        default:
            break
        }
        out.append(ch)
    }
    return out
}

private let blockStartRegex = try! NSRegularExpression(
    pattern: "^(?:#{1,6}(?: |$)|>|[-+*] |[-*_]{3,}|```|~~~|[0-9]{1,9}[.)] )")

/// Escaped den Zeilenanfang, wenn der Text sonst als Block-Syntax gelesen
/// würde („# nicht Überschrift", „1. nicht Liste", „- nicht Punkt").
private func escapeLineStart(_ line: String) -> String {
    let range = NSRange(line.startIndex..., in: line)
    guard blockStartRegex.firstMatch(in: line, range: range) != nil else { return line }
    if let first = line.first, first.isNumber,
       let marker = line.firstIndex(where: { $0 == "." || $0 == ")" }) {
        return String(line[..<marker]) + "\\" + String(line[marker...])
    }
    return "\\" + line
}

// MARK: - Helpers

extension ADFNode {
    /// Knoten als JSON-Dictionary (für Request-Bodies / Erhalt beim Editieren).
    func jsonDictionary() -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
