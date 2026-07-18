import Foundation

/// Konvertiert einen Markdown-String (Subset) in ein Jira-ADF-Request-Body-
/// Dictionary für POST /rest/api/3/issue/{key}/comment.
///
/// Unterstützt: fenced code blocks (```), inline code (`), fett (**),
/// kursiv (*), Überschriften (#…), Listen (-, 1.), Zitate (>), Links,
/// Mentions als `@[Name](accountId)` und Jira-Keys/Browse-Links als
/// native Ticket-Karten (inlineCard).
func markdownToADFBody(_ markdown: String, siteBaseURL: URL? = nil) -> [String: Any] {
    ["body": markdownToADFDoc(markdown, siteBaseURL: siteBaseURL)]
}

/// Das nackte ADF-Dokument (für PUT description).
func markdownToADFDoc(_ markdown: String, siteBaseURL: URL? = nil) -> [String: Any] {
    ["version": 1, "type": "doc",
     "content": parseBlocks(markdown, site: siteBaseURL)] as [String: Any]
}

// MARK: - Block parsing

private func parseBlocks(_ text: String, site: URL?) -> [[String: Any]] {
    var result: [[String: Any]] = []
    var lines = ArraySlice(text.components(separatedBy: "\n"))

    while !lines.isEmpty {
        let line = lines.removeFirst()

        if line.hasPrefix("```") {
            let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            var codeLines: [String] = []
            while let next = lines.first, !next.hasPrefix("```") {
                codeLines.append(next)
                lines = lines.dropFirst()
            }
            if !lines.isEmpty { lines = lines.dropFirst() } // closing ```

            var block: [String: Any] = [
                "type": "codeBlock",
                "content": [["type": "text", "text": codeLines.joined(separator: "\n")] as [String: Any]]
            ]
            if !lang.isEmpty { block["attrs"] = ["language": lang] as [String: Any] }
            result.append(block)

        } else if let heading = headingLevel(line) {
            result.append([
                "type": "heading",
                "attrs": ["level": heading.level] as [String: Any],
                "content": parseInline(heading.text, site: site),
            ])

        } else if isBulletLine(line) {
            var items = [String(line.dropFirst(2))]
            while let next = lines.first, isBulletLine(next) {
                items.append(String(next.dropFirst(2)))
                lines = lines.dropFirst()
            }
            result.append(["type": "bulletList", "content": items.map { listItem($0, site: site) }])

        } else if let first = orderedText(line) {
            var items = [first]
            while let next = lines.first, let text = orderedText(next) {
                items.append(text)
                lines = lines.dropFirst()
            }
            result.append(["type": "orderedList", "content": items.map { listItem($0, site: site) }])

        } else if line.hasPrefix("> ") || line == ">" {
            var quoted = [String(line.dropFirst(line == ">" ? 1 : 2))]
            while let next = lines.first, next.hasPrefix("> ") || next == ">" {
                quoted.append(String(next.dropFirst(next == ">" ? 1 : 2)))
                lines = lines.dropFirst()
            }
            result.append(["type": "blockquote",
                           "content": parseBlocks(quoted.joined(separator: "\n"), site: site)])

        } else if line.trimmingCharacters(in: .whitespaces) == "---" {
            result.append(["type": "rule"])

        } else if line.isEmpty {
            // Leerzeile trennt Absätze

        } else {
            // Aufeinanderfolgende nicht-leere Zeilen → ein Absatz mit hardBreaks
            var paraLines = [line]
            while let next = lines.first, !next.isEmpty, !next.hasPrefix("```"),
                  headingLevel(next) == nil, !isBulletLine(next),
                  orderedText(next) == nil, !next.hasPrefix("> ") {
                paraLines.append(next)
                lines = lines.dropFirst()
            }

            var inline: [[String: Any]] = []
            for (idx, paraLine) in paraLines.enumerated() {
                inline += parseInline(paraLine, site: site)
                if idx < paraLines.count - 1 {
                    inline.append(["type": "hardBreak"])
                }
            }
            result.append(["type": "paragraph", "content": inline])
        }
    }

    if result.isEmpty {
        result.append(["type": "paragraph",
                        "content": [["type": "text", "text": ""] as [String: Any]]])
    }
    return result
}

private func listItem(_ text: String, site: URL?) -> [String: Any] {
    ["type": "listItem",
     "content": [["type": "paragraph", "content": parseInline(text, site: site)] as [String: Any]]]
}

private func headingLevel(_ line: String) -> (level: Int, text: String)? {
    guard line.hasPrefix("#") else { return nil }
    let hashes = line.prefix(while: { $0 == "#" })
    guard hashes.count <= 6, line.dropFirst(hashes.count).hasPrefix(" ") else { return nil }
    return (hashes.count, String(line.dropFirst(hashes.count + 1)))
}

private func isBulletLine(_ line: String) -> Bool {
    line.hasPrefix("- ") || line.hasPrefix("* ")
}

private func orderedText(_ line: String) -> String? {
    guard let dot = line.firstIndex(of: "."),
          line.index(after: dot) < line.endIndex,
          line[line.index(after: dot)] == " ",
          !line[..<dot].isEmpty,
          line[..<dot].allSatisfy(\.isNumber) else { return nil }
    return String(line[line.index(dot, offsetBy: 2)...])
}

// MARK: - Inline parsing

private let jiraKeyRegex = try! NSRegularExpression(pattern: "^[A-Z][A-Z0-9_]*-[0-9]+")
private let mentionRegex = try! NSRegularExpression(pattern: "^@\\[([^\\]]+)\\]\\(([^)]+)\\)")

private func parseInline(_ text: String, site: URL?) -> [[String: Any]] {
    var nodes: [[String: Any]] = []
    var plain = ""
    var i = text.startIndex

    func flush() {
        guard !plain.isEmpty else { return }
        nodes.append(["type": "text", "text": plain])
        plain = ""
    }

    /// Steht der Cursor an einer Wortgrenze (Anfang oder nach Nicht-Wortzeichen)?
    func atWordBoundary() -> Bool {
        guard let last = plain.last else { return true }
        return !(last.isLetter || last.isNumber)
    }

    while i < text.endIndex {
        let ch = text[i]
        let next = text.index(after: i)
        let rest = String(text[i...])

        // Mention-Token: @[Display Name](accountId)
        if ch == "@" {
            let range = NSRange(rest.startIndex..., in: rest)
            if let match = mentionRegex.firstMatch(in: rest, range: range),
               let nameRange = Range(match.range(at: 1), in: rest),
               let idRange = Range(match.range(at: 2), in: rest),
               let fullRange = Range(match.range, in: rest) {
                flush()
                nodes.append(["type": "mention",
                              "attrs": ["id": String(rest[idRange]),
                                        "text": "@" + rest[nameRange]] as [String: Any]])
                i = text.index(i, offsetBy: rest.distance(from: rest.startIndex, to: fullRange.upperBound))
                continue
            }
        }

        // URLs: Browse-Links werden zur Ticket-Karte, andere zu Links.
        if ch == "h", rest.hasPrefix("http://") || rest.hasPrefix("https://") {
            let urlString = String(rest.prefix(while: { !$0.isWhitespace }))
            flush()
            if urlString.contains("/browse/"), JiraKeyParser.key(from: urlString) != nil {
                nodes.append(["type": "inlineCard", "attrs": ["url": urlString] as [String: Any]])
            } else {
                nodes.append(["type": "text", "text": urlString,
                              "marks": [["type": "link",
                                         "attrs": ["href": urlString] as [String: Any]] as [String: Any]]])
            }
            i = text.index(i, offsetBy: urlString.count)
            continue
        }

        // Nackte Jira-Keys (ONE-9191) → Ticket-Karte, wenn die Site bekannt ist.
        if let site, ch.isUppercase, atWordBoundary() {
            let range = NSRange(rest.startIndex..., in: rest)
            if let match = jiraKeyRegex.firstMatch(in: rest, range: range),
               let keyRange = Range(match.range, in: rest) {
                let key = String(rest[keyRange])
                let after = keyRange.upperBound
                let boundaryAfter = after == rest.endIndex
                    || !(rest[after].isLetter || rest[after].isNumber)
                if boundaryAfter {
                    flush()
                    let url = site.absoluteString + "/browse/" + key
                    nodes.append(["type": "inlineCard", "attrs": ["url": url] as [String: Any]])
                    i = text.index(i, offsetBy: key.count)
                    continue
                }
            }
        }

        // Inline code: `...`
        if ch == "`" {
            if let end = text[next...].firstIndex(of: "`") {
                flush()
                nodes.append(["type": "text", "text": String(text[next..<end]),
                               "marks": [["type": "code"] as [String: Any]]])
                i = text.index(after: end)
                continue
            }
        }

        // Bold: **...**
        if ch == "*", next < text.endIndex, text[next] == "*" {
            let afterTwo = text.index(after: next)
            if let endRange = text[afterTwo...].range(of: "**") {
                flush()
                nodes.append(["type": "text", "text": String(text[afterTwo..<endRange.lowerBound]),
                               "marks": [["type": "strong"] as [String: Any]]])
                i = endRange.upperBound
                continue
            }
        }

        // Italic: *...* (nur wenn kein **)
        if ch == "*", !(next < text.endIndex && text[next] == "*") {
            if let end = text[next...].firstIndex(of: "*") {
                flush()
                nodes.append(["type": "text", "text": String(text[next..<end]),
                               "marks": [["type": "em"] as [String: Any]]])
                i = text.index(after: end)
                continue
            }
        }

        plain.append(ch)
        i = next
    }

    flush()
    return nodes.isEmpty ? [["type": "text", "text": ""]] : nodes
}
