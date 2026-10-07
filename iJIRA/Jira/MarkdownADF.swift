import Foundation

/// Konvertiert einen Markdown-String in ein Jira-ADF-Request-Body-
/// Dictionary für POST /rest/api/3/issue/{key}/comment.
///
/// Unterstützt (GitHub-Flavored-Markdown-nah, damit eingefügtes Markdown
/// so ankommt wie geschrieben):
/// - Blöcke: Absätze, Überschriften (#…), Code-Fences (``` und ~~~), Zitate (>),
///   Trennlinien (---, ***, ___), Tabellen (| a | b |), Listen (-, *, +, 1., 1))
///   inkl. Verschachtelung per Einrückung und Aufgaben (- [ ] / - [x]).
/// - Inline: **fett**/__fett__, *kursiv*/_kursiv_, ***beides***, ~~durch~~,
///   `code`, [Link](url), <url>, nackte URLs, Escapes (\*), <br>,
///   Mentions als `@[Name](accountId)` und Jira-Keys/Browse-Links als native
///   Ticket-Karten (inlineCard).
///
/// Abweichung von CommonMark: Zeilenumbrüche innerhalb eines Absatzes bleiben
/// Zeilenumbrüche (hardBreak) — der Editor ist chat-artig.
func markdownToADFBody(_ markdown: String, siteBaseURL: URL? = nil) -> [String: Any] {
    ["body": markdownToADFDoc(markdown, siteBaseURL: siteBaseURL)]
}

/// Das nackte ADF-Dokument (für PUT description).
func markdownToADFDoc(_ markdown: String, siteBaseURL: URL? = nil) -> [String: Any] {
    let normalized = markdown
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
    var blocks = parseBlocks(normalized, site: siteBaseURL)
    if blocks.isEmpty {
        blocks.append(["type": "paragraph",
                       "content": [["type": "text", "text": ""] as [String: Any]]])
    }
    return ["version": 1, "type": "doc", "content": blocks] as [String: Any]
}

// MARK: - Block parsing

private func parseBlocks(_ text: String, site: URL?) -> [[String: Any]] {
    var result: [[String: Any]] = []
    var lines = ArraySlice(text.components(separatedBy: "\n"))

    while let line = lines.first {
        if let fence = codeFence(line) {
            lines.removeFirst()
            var codeLines: [String] = []
            while let next = lines.first {
                lines.removeFirst()
                if isClosingFence(next, for: fence) { break }
                codeLines.append(stripIndent(next, upTo: fence.indent))
            }
            var block: [String: Any] = [
                "type": "codeBlock",
                "content": [["type": "text", "text": codeLines.joined(separator: "\n")] as [String: Any]],
            ]
            // Leerer Code-Block: ADF verbietet leere Textknoten.
            if codeLines.joined().isEmpty { block["content"] = [] as [[String: Any]] }
            if !fence.language.isEmpty { block["attrs"] = ["language": fence.language] as [String: Any] }
            result.append(block)

        } else if let heading = headingLevel(line) {
            lines.removeFirst()
            result.append([
                "type": "heading",
                "attrs": ["level": heading.level] as [String: Any],
                "content": parseInline(heading.text, site: site),
            ])

        } else if isRule(line) {
            lines.removeFirst()
            result.append(["type": "rule"])

        } else if isTableStart(line, delimiter: lines.dropFirst().first) {
            result.append(parseTable(&lines, site: site))

        } else if listLine(line) != nil {
            result.append(contentsOf: parseList(&lines, site: site))

        } else if let quoted = quoteText(line) {
            lines.removeFirst()
            var quotedLines = [quoted]
            while let next = lines.first, let text = quoteText(next) {
                quotedLines.append(text)
                lines.removeFirst()
            }
            var inner = parseBlocks(quotedLines.joined(separator: "\n"), site: site)
            if inner.isEmpty { inner = [["type": "paragraph", "content": [] as [[String: Any]]]] }
            result.append(["type": "blockquote", "content": inner])

        } else if let media = mediaSingles(from: line) {
            lines.removeFirst()
            result.append(contentsOf: media)

        } else if isBlank(line) {
            // Leerzeile trennt Absätze
            lines.removeFirst()

        } else {
            // Aufeinanderfolgende nicht-leere Zeilen → ein Absatz mit hardBreaks
            lines.removeFirst()
            var paraLines = [line]
            while let next = lines.first, !isBlank(next),
                  !startsBlock(next, following: lines.dropFirst().first) {
                paraLines.append(next)
                lines.removeFirst()
            }
            let inline = joinLines(paraLines.map { $0.trimmingCharacters(in: .whitespaces) }, site: site)
            result.append(["type": "paragraph", "content": inline])
        }
    }
    return result
}

/// Beginnt mit dieser Zeile ein neuer Block (beendet also einen Absatz)?
private func startsBlock(_ line: String, following: String?) -> Bool {
    codeFence(line) != nil || headingLevel(line) != nil || isRule(line)
        || isTableStart(line, delimiter: following) || listLine(line) != nil
        || quoteText(line) != nil || mediaSingles(from: line) != nil
}

/// Zeilen eines Absatzes/Listenpunkts → Inline-Knoten mit hardBreaks dazwischen.
private func joinLines(_ lines: [String], site: URL?) -> [[String: Any]] {
    var inline: [[String: Any]] = []
    for (idx, line) in lines.enumerated() {
        if idx > 0 { inline.append(["type": "hardBreak"]) }
        inline += parseInline(line, site: site)
    }
    return inline
}

private func isBlank(_ line: String) -> Bool {
    line.allSatisfy { $0 == " " || $0 == "\t" }
}

/// Führende Leerzeichen (Tab = 4).
private func indentation(_ line: String) -> Int {
    var width = 0
    for ch in line {
        if ch == " " { width += 1 }
        else if ch == "\t" { width += 4 }
        else { break }
    }
    return width
}

private func stripIndent(_ line: String, upTo count: Int) -> String {
    var dropped = 0
    var index = line.startIndex
    while dropped < count, index < line.endIndex, line[index] == " " {
        dropped += 1
        index = line.index(after: index)
    }
    return String(line[index...])
}

// MARK: Überschriften, Linien, Zitate, Code

private func headingLevel(_ line: String) -> (level: Int, text: String)? {
    guard indentation(line) <= 3 else { return nil }
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("#") else { return nil }
    let hashes = trimmed.prefix(while: { $0 == "#" })
    guard hashes.count <= 6, trimmed.dropFirst(hashes.count).hasPrefix(" ") else { return nil }
    var text = trimmed.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)
    // Optionale schließende Rauten: "## Titel ##"
    if let range = text.range(of: " #+$", options: .regularExpression) {
        text = String(text[..<range.lowerBound])
    } else if text.allSatisfy({ $0 == "#" }) {
        text = ""
    }
    guard !text.isEmpty else { return nil }
    return (hashes.count, text)
}

private let ruleRegex = try! NSRegularExpression(pattern: "^ {0,3}([-*_])(?:[ \\t]*\\1){2,}[ \\t]*$")

private func isRule(_ line: String) -> Bool {
    ruleRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
}

private func quoteText(_ line: String) -> String? {
    guard indentation(line) <= 3 else { return nil }
    let trimmed = line.drop(while: { $0 == " " })
    guard trimmed.hasPrefix(">") else { return nil }
    let rest = trimmed.dropFirst()
    return String(rest.hasPrefix(" ") ? rest.dropFirst() : rest)
}

private struct CodeFence {
    let marker: String
    let indent: Int
    let language: String
}

private func codeFence(_ line: String) -> CodeFence? {
    let indent = indentation(line)
    guard indent <= 3 else { return nil }
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
    let marker = String(trimmed.prefix(while: { $0 == first }))
    guard marker.count >= 3 else { return nil }
    let info = trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
    // Bei ```-Fences darf die Info-Zeile keinen Backtick enthalten (sonst
    // wäre es Inline-Code wie ```foo```).
    if first == "`", info.contains("`") { return nil }
    let language = info.split(separator: " ").first.map(String.init) ?? ""
    return CodeFence(marker: marker, indent: indent, language: language)
}

private func isClosingFence(_ line: String, for fence: CodeFence) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard let ch = fence.marker.first, trimmed.hasPrefix(fence.marker) else { return false }
    return trimmed.allSatisfy { $0 == ch }
}

// MARK: Tabellen (GFM)

private let delimiterCellRegex = try! NSRegularExpression(pattern: "^:?-+:?$")

/// Tabellenanfang: Kopfzeile mit Pipes, darunter eine Trennzeile
/// (`|---|:---:|`) mit gleich vielen Spalten.
private func isTableStart(_ line: String, delimiter: String?) -> Bool {
    guard let delimiter, line.contains("|"), indentation(line) <= 3,
          isDelimiterRow(delimiter) else { return false }
    return splitTableRow(line).count == splitTableRow(delimiter).count
}

private func isDelimiterRow(_ line: String) -> Bool {
    guard line.contains("-"), indentation(line) <= 3 else { return false }
    let cells = splitTableRow(line)
    // Eine einspaltige Trennzeile ohne Pipe wäre eine Trennlinie bzw. ein
    // Setext-Unterstrich, keine Tabelle.
    guard !cells.isEmpty, line.contains("|") else { return false }
    return cells.allSatisfy { cell in
        delimiterCellRegex.firstMatch(in: cell, range: NSRange(cell.startIndex..., in: cell)) != nil
    }
}

/// Zerlegt eine Tabellenzeile an nicht-escapeten Pipes. Äußere Pipes sind
/// optional; `\|` wird zur literalen Pipe (auch in Inline-Code, wie bei GFM).
private func splitTableRow(_ line: String) -> [String] {
    var trimmed = Substring(line.trimmingCharacters(in: .whitespaces))
    if trimmed.hasPrefix("|") { trimmed = trimmed.dropFirst() }
    if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|") { trimmed = trimmed.dropLast() }

    var cells: [String] = []
    var current = ""
    var escaped = false
    for ch in trimmed {
        if escaped {
            // Nur `\|` wird hier aufgelöst; alle anderen Escapes bleiben für
            // den Inline-Parser stehen.
            if ch != "|" { current.append("\\") }
            current.append(ch)
            escaped = false
        } else if ch == "\\" {
            escaped = true
        } else if ch == "|" {
            cells.append(current.trimmingCharacters(in: .whitespaces))
            current = ""
        } else {
            current.append(ch)
        }
    }
    if escaped { current.append("\\") }
    cells.append(current.trimmingCharacters(in: .whitespaces))
    return cells
}

private func parseTable(_ lines: inout ArraySlice<String>, site: URL?) -> [String: Any] {
    let header = splitTableRow(lines.removeFirst())
    lines.removeFirst() // Trennzeile
    let columns = header.count

    var bodyRows: [[String]] = []
    while let next = lines.first, !isBlank(next), next.contains("|"),
          codeFence(next) == nil, headingLevel(next) == nil, quoteText(next) == nil {
        var cells = splitTableRow(next)
        if cells.count < columns { cells += Array(repeating: "", count: columns - cells.count) }
        bodyRows.append(Array(cells.prefix(columns)))
        lines.removeFirst()
    }

    func row(_ cells: [String], header: Bool) -> [String: Any] {
        ["type": "tableRow",
         "content": cells.map { cell in
             ["type": header ? "tableHeader" : "tableCell",
              "attrs": [:] as [String: Any],
              "content": [["type": "paragraph",
                           "content": parseInline(cell, site: site)] as [String: Any]]] as [String: Any]
         }]
    }

    var rows: [[String: Any]] = []
    // Komplett leere Kopfzeile = Tabelle ohne Kopfzeile. So kommt eine
    // kopflose Jira-Tabelle unverändert durch den Markdown-Editor (siehe
    // `adfToMarkdown`); Markdown selbst verlangt immer eine Kopfzeile.
    if !header.allSatisfy(\.isEmpty) {
        rows.append(row(header, header: true))
    }
    rows += bodyRows.map { row($0, header: false) }
    if rows.isEmpty {
        rows.append(row(Array(repeating: "", count: columns), header: false))
    }
    return ["type": "table",
            "attrs": ["isNumberColumnEnabled": false, "layout": "default"] as [String: Any],
            "content": rows]
}

// MARK: Listen

private enum ListFamily {
    case bullet, ordered, task
}

private struct ListLine {
    let indent: Int
    let family: ListFamily
    let number: Int
    let done: Bool
    let text: String
}

private let listLineRegex = try! NSRegularExpression(pattern: "^([ \\t]*)([-*+]|[0-9]{1,9}[.)])[ \\t]+(.*)$")
private let taskPrefixRegex = try! NSRegularExpression(pattern: "^\\[([ xX])\\](?:[ \\t]+(.*))?$")

private func listLine(_ line: String) -> ListLine? {
    let range = NSRange(line.startIndex..., in: line)
    guard let match = listLineRegex.firstMatch(in: line, range: range),
          let indentRange = Range(match.range(at: 1), in: line),
          let markerRange = Range(match.range(at: 2), in: line),
          let textRange = Range(match.range(at: 3), in: line) else { return nil }
    let indent = indentation(String(line[indentRange]))
    let marker = line[markerRange]
    let text = String(line[textRange])

    if let number = Int(marker.dropLast()) {
        return ListLine(indent: indent, family: .ordered, number: number, done: false, text: text)
    }
    let textNS = NSRange(text.startIndex..., in: text)
    if let task = taskPrefixRegex.firstMatch(in: text, range: textNS),
       let stateRange = Range(task.range(at: 1), in: text) {
        let rest = Range(task.range(at: 2), in: text).map { String(text[$0]) } ?? ""
        return ListLine(indent: indent, family: .task, number: 1,
                        done: text[stateRange] != " ", text: rest)
    }
    return ListLine(indent: indent, family: .bullet, number: 1, done: false, text: text)
}

/// Ein Listenpunkt im Aufbau: Textzeilen plus verschachtelte Listen.
private struct PendingItem {
    var lines: [String]
    var nested: [[String: Any]] = []
    let done: Bool
}

/// Liest eine Liste ab der aktuellen Zeile. Tiefer eingerückte Listenzeilen
/// (≥ 2 Leerzeichen) werden zur Unterliste des vorigen Punkts, eingerückte
/// Nicht-Listenzeilen zur Fortsetzung seines Texts.
///
/// Liefert mehrere Knoten, wenn ADF eine Verschachtelung nicht abbilden kann
/// (Aufgaben unter normalen Listenpunkten und umgekehrt): die Liste wird dann
/// aufgeteilt und die Unterliste steht zwischen den Teilen.
private func parseList(_ lines: inout ArraySlice<String>, site: URL?) -> [[String: Any]] {
    guard let first = lines.first.flatMap(listLine) else { return [] }
    let base = first.indent
    var output: [[String: Any]] = []
    var items: [PendingItem] = []
    var start = first.number

    func flush() {
        guard !items.isEmpty else { return }
        output.append(listNode(first.family, items: items, start: start, site: site))
        start += items.count
        items = []
    }

    while let line = lines.first {
        if let item = listLine(line) {
            if item.indent < base { break }
            if item.indent >= base + 2, !items.isEmpty {
                for node in parseList(&lines, site: site) {
                    let isTask = node["type"] as? String == "taskList"
                    if isTask == (first.family == .task) {
                        items[items.count - 1].nested.append(node)
                    } else {
                        flush()
                        output.append(node)
                    }
                }
                continue
            }
            guard item.family == first.family else { break }
            lines.removeFirst()
            items.append(PendingItem(lines: [item.text], done: item.done))
        } else if isBlank(line) {
            // Leerzeilen zwischen Punkten („lockere" Liste) beenden die Liste
            // nur, wenn danach nichts mehr zu ihr gehört.
            guard let following = lines.dropFirst().first(where: { !isBlank($0) }),
                  let item = listLine(following), item.indent >= base,
                  item.indent >= base + 2 || item.family == first.family else { break }
            lines.removeFirst()
        } else if indentation(line) >= base + 2, !items.isEmpty, items[items.count - 1].nested.isEmpty {
            lines.removeFirst()
            items[items.count - 1].lines.append(line.trimmingCharacters(in: .whitespaces))
        } else {
            break
        }
    }
    flush()
    return output
}

private func listNode(_ family: ListFamily, items: [PendingItem], start: Int, site: URL?) -> [String: Any] {
    switch family {
    case .bullet, .ordered:
        let content: [[String: Any]] = items.map { item in
            ["type": "listItem",
             "content": [["type": "paragraph",
                          "content": joinLines(item.lines, site: site)] as [String: Any]] + item.nested]
        }
        if family == .bullet {
            return ["type": "bulletList", "content": content]
        }
        var node: [String: Any] = ["type": "orderedList", "content": content]
        if start != 1 { node["attrs"] = ["order": start] as [String: Any] }
        return node

    case .task:
        var content: [[String: Any]] = []
        for item in items {
            content.append(["type": "taskItem",
                            "attrs": ["localId": UUID().uuidString,
                                      "state": item.done ? "DONE" : "TODO"] as [String: Any],
                            "content": joinLines(item.lines, site: site)])
            // Unteraufgaben stehen in ADF als Geschwister-taskList.
            content += item.nested
        }
        return ["type": "taskList",
                "attrs": ["localId": UUID().uuidString] as [String: Any],
                "content": content]
    }
}

// MARK: Media-Tokens

/// Media-Tokens aus dem Drop-Upload: eine Zeile, die nur aus
/// `![alt](media:uuid)`-Tokens (+ Whitespace) besteht → je Token ein
/// `mediaSingle`-Block. Die UUID stammt aus den Media-Services (siehe
/// JiraClient.mediaUUID); der alt-Text trägt den Dateinamen.
private let mediaLineRegex = try! NSRegularExpression(
    pattern: "^\\s*(?:!\\[[^\\]]*\\]\\(media:[0-9a-fA-F-]+\\)\\s*)+$")
private let mediaTokenRegex = try! NSRegularExpression(
    pattern: "!\\[([^\\]]*)\\]\\(media:([0-9a-fA-F-]+)\\)")

private func mediaSingles(from line: String) -> [[String: Any]]? {
    let full = NSRange(line.startIndex..., in: line)
    guard mediaLineRegex.firstMatch(in: line, range: full) != nil else { return nil }
    var nodes: [[String: Any]] = []
    mediaTokenRegex.enumerateMatches(in: line, range: full) { match, _, _ in
        guard let match,
              let altRange = Range(match.range(at: 1), in: line),
              let idRange = Range(match.range(at: 2), in: line) else { return }
        nodes.append([
            "type": "mediaSingle",
            "attrs": ["layout": "align-start"] as [String: Any],
            "content": [[
                "type": "media",
                "attrs": ["type": "file",
                          "id": String(line[idRange]),
                          "collection": "",
                          "alt": String(line[altRange])] as [String: Any],
            ] as [String: Any]],
        ])
    }
    return nodes.isEmpty ? nil : nodes
}

// MARK: - Inline parsing

private let jiraKeyRegex = try! NSRegularExpression(pattern: "^[A-Z][A-Z0-9_]*-[0-9]+")
private let mentionRegex = try! NSRegularExpression(pattern: "^@\\[([^\\]]+)\\]\\(([^)]+)\\)")
private let breakTagRegex = try! NSRegularExpression(pattern: "^<br\\s*/?>", options: .caseInsensitive)
private let autolinkRegex = try! NSRegularExpression(pattern: "^<((?:https?://|mailto:)[^>\\s]+)>")
private let markdownPunctuation = Set("\\`*_{}[]()<>#+-.!|~")

private func parseInline(_ text: String, site: URL?) -> [[String: Any]] {
    InlineParser(chars: Array(text), site: site).parse(marks: [])
}

/// Rekursiver Inline-Parser: Hervorhebungen und Link-Texte werden mit den
/// geerbten Marks erneut geparst, so dass z. B. **fett mit `code`** oder
/// [**fetter** Link](url) korrekt verschachtelt ankommen.
private struct InlineParser {
    let chars: [Character]
    let site: URL?

    func parse(marks: [[String: Any]]) -> [[String: Any]] {
        parse(range: 0..<chars.count, marks: marks)
    }

    private func parse(range: Range<Int>, marks: [[String: Any]]) -> [[String: Any]] {
        var nodes: [[String: Any]] = []
        var plain = ""
        var i = range.lowerBound
        let end = range.upperBound

        func flush() {
            guard !plain.isEmpty else { return }
            nodes.append(textNode(plain, marks: marks))
            plain = ""
        }

        func rest(_ from: Int) -> String { String(chars[from..<end]) }

        /// Steht der Cursor an einer Wortgrenze (Anfang oder nach Nicht-Wortzeichen)?
        func atWordBoundary(_ index: Int) -> Bool {
            guard index > range.lowerBound else { return true }
            let last = chars[index - 1]
            return !(last.isLetter || last.isNumber)
        }

        while i < end {
            let ch = chars[i]

            // Escape: \* → literales *
            if ch == "\\", i + 1 < end, markdownPunctuation.contains(chars[i + 1]) {
                plain.append(chars[i + 1])
                i += 2
                continue
            }

            // Zeilenumbruch: <br>, <br/>, <br /> (in Tabellenzellen üblich)
            if ch == "<" {
                let tail = rest(i)
                let ns = NSRange(tail.startIndex..., in: tail)
                if let match = breakTagRegex.firstMatch(in: tail, range: ns) {
                    flush()
                    nodes.append(["type": "hardBreak"])
                    i += tail.utf16Prefix(match.range.length)
                    continue
                }
                if let match = autolinkRegex.firstMatch(in: tail, range: ns),
                   let urlRange = Range(match.range(at: 1), in: tail) {
                    flush()
                    let url = String(tail[urlRange])
                    nodes.append(linkOrCard(url, label: nil, marks: marks))
                    i += tail.utf16Prefix(match.range.length)
                    continue
                }
            }

            // Mention-Token: @[Display Name](accountId)
            if ch == "@" {
                let tail = rest(i)
                if let match = mentionRegex.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)),
                   let nameRange = Range(match.range(at: 1), in: tail),
                   let idRange = Range(match.range(at: 2), in: tail) {
                    flush()
                    nodes.append(["type": "mention",
                                  "attrs": ["id": String(tail[idRange]),
                                            "text": "@" + tail[nameRange]] as [String: Any]])
                    i += tail.utf16Prefix(match.range.length)
                    continue
                }
            }

            // Nackte URLs: Browse-Links werden zur Ticket-Karte, andere zu Links.
            if ch == "h", atWordBoundary(i), hasPrefix("http://", at: i, end: end) || hasPrefix("https://", at: i, end: end) {
                let length = bareURLLength(from: i, end: end)
                flush()
                nodes.append(linkOrCard(String(chars[i..<i + length]), label: nil, marks: marks))
                i += length
                continue
            }

            // Nackte Jira-Keys (ONE-9191) → Ticket-Karte, wenn die Site bekannt ist.
            if let site, ch.isUppercase, atWordBoundary(i) {
                let tail = rest(i)
                if let match = jiraKeyRegex.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)),
                   let keyRange = Range(match.range, in: tail) {
                    let key = String(tail[keyRange])
                    let after = i + key.count
                    let boundaryAfter = after >= end || !(chars[after].isLetter || chars[after].isNumber)
                    if boundaryAfter {
                        flush()
                        let url = site.absoluteString + "/browse/" + key
                        nodes.append(["type": "inlineCard", "attrs": ["url": url] as [String: Any]])
                        i = after
                        continue
                    }
                }
            }

            // Markdown-Link [Text](url) bzw. Bild ![alt](url) → Link
            if ch == "[" || (ch == "!" && i + 1 < end && chars[i + 1] == "[") {
                let open = ch == "!" ? i + 1 : i
                if let link = markdownLink(openBracket: open, end: end) {
                    flush()
                    if ch == "!" {
                        let alt = String(chars[link.label])
                        nodes.append(linkOrCard(link.href, label: alt.isEmpty ? nil : alt, marks: marks))
                    } else {
                        let linkMark: [String: Any] = ["type": "link",
                                                       "attrs": ["href": link.href] as [String: Any]]
                        let inner = parse(range: link.label, marks: marks + [linkMark])
                        nodes += inner.isEmpty ? [textNode(link.href, marks: marks + [linkMark])] : inner
                    }
                    i = link.end
                    continue
                }
            }

            // Inline code: `...` bzw. ``...``
            if ch == "`" {
                let ticks = run(of: "`", at: i, end: end)
                if let close = findCodeClose(ticks: ticks, from: i + ticks, end: end) {
                    var code = String(chars[(i + ticks)..<close])
                    if code.count > 2, code.hasPrefix(" "), code.hasSuffix(" ") {
                        code = String(code.dropFirst().dropLast())
                    }
                    flush()
                    if !code.isEmpty {
                        // ADF erlaubt `code` nur zusammen mit `link`.
                        let kept = marks.filter { $0["type"] as? String == "link" }
                        nodes.append(textNode(code, marks: kept + [["type": "code"]]))
                    }
                    i = close + ticks
                    continue
                }
                plain += String(repeating: "`", count: ticks)
                i += ticks
                continue
            }

            // Hervorhebungen: *, **, ***, _, __, ___, ~~
            if ch == "*" || ch == "_" || ch == "~" {
                let length = min(run(of: ch, at: i, end: end), 3)
                if let emphasis = emphasis(char: ch, length: length, at: i, end: end, range: range) {
                    flush()
                    nodes += parse(range: emphasis.inner, marks: marks + emphasis.marks)
                    i = emphasis.end
                    continue
                }
                // Kein Partner: ganze Zeichenfolge literal übernehmen (sonst
                // würde z. B. das zweite * von ** als Kursiv-Öffner gelesen).
                let literal = run(of: ch, at: i, end: end)
                plain += String(repeating: String(ch), count: literal)
                i += literal
                continue
            }

            plain.append(ch)
            i += 1
        }

        flush()
        return nodes
    }

    // MARK: Hilfen

    private func textNode(_ text: String, marks: [[String: Any]]) -> [String: Any] {
        var node: [String: Any] = ["type": "text", "text": text]
        if !marks.isEmpty { node["marks"] = marks }
        return node
    }

    /// Browse-Link derselben Jira-Instanz → Ticket-Karte, sonst Link-Text.
    private func linkOrCard(_ url: String, label: String?, marks: [[String: Any]]) -> [String: Any] {
        if label == nil, url.contains("/browse/"), JiraKeyParser.key(from: url) != nil {
            return ["type": "inlineCard", "attrs": ["url": url] as [String: Any]]
        }
        let linkMark: [String: Any] = ["type": "link", "attrs": ["href": url] as [String: Any]]
        return textNode(label ?? url, marks: marks.filter { $0["type"] as? String != "link" } + [linkMark])
    }

    private func hasPrefix(_ prefix: String, at index: Int, end: Int) -> Bool {
        let p = Array(prefix)
        guard index + p.count <= end else { return false }
        return Array(chars[index..<index + p.count]) == p
    }

    private func run(of ch: Character, at index: Int, end: Int) -> Int {
        var n = 0
        while index + n < end, chars[index + n] == ch { n += 1 }
        return n
    }

    /// Länge einer nackten URL: bis zum Whitespace, ohne abschließende
    /// Satzzeichen ("siehe https://x.de/a." → ohne Punkt) und ohne
    /// unbalancierte schließende Klammer ("(https://x.de)").
    private func bareURLLength(from start: Int, end: Int) -> Int {
        var stop = start
        while stop < end, !chars[stop].isWhitespace, chars[stop] != "<" { stop += 1 }
        while stop > start {
            let last = chars[stop - 1]
            if ".,;:!?*_~'\"".contains(last) {
                stop -= 1
            } else if last == ")" {
                let opens = chars[start..<stop].filter { $0 == "(" }.count
                let closes = chars[start..<stop].filter { $0 == ")" }.count
                if closes > opens { stop -= 1 } else { break }
            } else {
                break
            }
        }
        return stop - start
    }

    /// `[label](href "optionaler Titel")` ab der öffnenden Klammer.
    private func markdownLink(openBracket: Int, end: Int) -> (label: Range<Int>, href: String, end: Int)? {
        // Passende schließende Klammer (verschachtelte [] zulassen).
        var depth = 0
        var close: Int?
        var j = openBracket
        while j < end {
            if chars[j] == "\\" { j += 2; continue }
            if chars[j] == "[" { depth += 1 }
            if chars[j] == "]" {
                depth -= 1
                if depth == 0 { close = j; break }
            }
            j += 1
        }
        guard let close, close + 1 < end, chars[close + 1] == "(" else { return nil }
        guard let closeParen = chars[(close + 2)..<end].firstIndex(of: ")") else { return nil }
        var target = String(chars[(close + 2)..<closeParen]).trimmingCharacters(in: .whitespaces)
        if let space = target.firstIndex(of: " ") { target = String(target[..<space]) }
        if target.hasPrefix("<"), target.hasSuffix(">") { target = String(target.dropFirst().dropLast()) }
        guard target.hasPrefix("http://") || target.hasPrefix("https://") || target.hasPrefix("mailto:") else {
            return nil
        }
        return (openBracket + 1..<close, target, closeParen + 1)
    }

    private func findCodeClose(ticks: Int, from start: Int, end: Int) -> Int? {
        var j = start
        while j < end {
            if chars[j] == "`" {
                let n = run(of: "`", at: j, end: end)
                if n == ticks { return j }
                j += n
            } else {
                j += 1
            }
        }
        return nil
    }

    /// Hervorhebung ab `index`: Öffner der Länge `length` aus `char`, passender
    /// Schließer. Regeln (vereinfachtes CommonMark):
    /// - nach dem Öffner / vor dem Schließer kein Leerzeichen (`5 * 3` bleibt Text),
    /// - `_` nur an Wortgrenzen (snake_case bleibt Text),
    /// - `~` nur doppelt (~~durch~~),
    /// - innere Öffner werden mitgezählt, damit `*a **b** c*` und
    ///   `**fett *kursiv***` richtig aufgehen.
    private func emphasis(char: Character, length: Int, at index: Int, end: Int,
                          range: Range<Int>) -> (inner: Range<Int>, marks: [[String: Any]], end: Int)? {
        if char == "~" && length != 2 { return nil }
        let innerStart = index + length
        guard innerStart < end, !chars[innerStart].isWhitespace else { return nil }
        if char == "_", index > range.lowerBound, isWordChar(chars[index - 1]) { return nil }

        var openers: [Int] = []
        var j = innerStart
        while j < end {
            let c = chars[j]
            if c == "\\" { j += 2; continue }
            if c == "`" {
                // Code-Spans überspringen — darin gibt es keine Hervorhebung.
                let ticks = run(of: "`", at: j, end: end)
                if let close = findCodeClose(ticks: ticks, from: j + ticks, end: end) {
                    j = close + ticks
                } else {
                    j += ticks
                }
                continue
            }
            guard c == char else { j += 1; continue }

            let n = run(of: char, at: j, end: end)
            let before = chars[j - 1]
            let after: Character? = j + n < end ? chars[j + n] : nil
            if char == "_", isWordChar(before), let after, isWordChar(after) {
                j += n // snake_case
                continue
            }
            let canClose = j > innerStart && !before.isWhitespace
                && !(char == "_" && after.map(isWordChar) == true)
            let canOpen = after.map { !$0.isWhitespace } ?? false

            if canClose {
                if openers.isEmpty, n == length {
                    return (innerStart..<j, marks(char: char, length: length), j + n)
                }
                if let top = openers.last, n > length, top == n - length {
                    // Schließer teilt sich den Lauf mit dem eines inneren Öffners.
                    return (innerStart..<(j + top), marks(char: char, length: length), j + n)
                }
                if let top = openers.last, top == n {
                    openers.removeLast()
                    j += n
                    continue
                }
            }
            if canOpen { openers.append(n) }
            j += n
        }
        return nil
    }

    private func marks(char: Character, length: Int) -> [[String: Any]] {
        switch (char, length) {
        case ("~", _): return [["type": "strike"]]
        case (_, 1): return [["type": "em"]]
        case (_, 2): return [["type": "strong"]]
        default: return [["type": "strong"], ["type": "em"]]
        }
    }

    private func isWordChar(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber
    }
}

private extension String {
    /// Anzahl Characters, die die ersten `utf16Length` UTF-16-Einheiten
    /// belegen (NSRegularExpression rechnet in UTF-16).
    func utf16Prefix(_ utf16Length: Int) -> Int {
        let index = String.Index(utf16Offset: utf16Length, in: self)
        return distance(from: startIndex, to: index)
    }
}
