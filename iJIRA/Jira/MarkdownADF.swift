import Foundation

/// Konvertiert einen Markdown-String (Subset) in ein Jira-ADF-Request-Body-Dictionary
/// für POST /rest/api/3/issue/{key}/comment.
/// Unterstützt: fenced code blocks (```), inline code (`), fett (**), kursiv (*).
func markdownToADFBody(_ markdown: String) -> [String: Any] {
    let blocks = parseBlocks(markdown)
    return ["body": ["version": 1, "type": "doc", "content": blocks] as [String: Any]]
}

// MARK: - Block parsing

private func parseBlocks(_ text: String) -> [[String: Any]] {
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

        } else if line.isEmpty {
            // Leerzeile trennt Absätze

        } else {
            // Aufeinanderfolgende nicht-leere Zeilen → ein Absatz mit hardBreaks
            var paraLines = [line]
            while let next = lines.first, !next.isEmpty, !next.hasPrefix("```") {
                paraLines.append(next)
                lines = lines.dropFirst()
            }

            var inline: [[String: Any]] = []
            for (idx, paraLine) in paraLines.enumerated() {
                inline += parseInline(paraLine)
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

// MARK: - Inline parsing

private func parseInline(_ text: String) -> [[String: Any]] {
    var nodes: [[String: Any]] = []
    var plain = ""
    var i = text.startIndex

    func flush() {
        guard !plain.isEmpty else { return }
        nodes.append(["type": "text", "text": plain])
        plain = ""
    }

    while i < text.endIndex {
        let ch = text[i]
        let next = text.index(after: i)

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
