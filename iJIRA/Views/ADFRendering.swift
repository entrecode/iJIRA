import SwiftUI

/// SwiftUI-seitige ADF-Darstellung: erzeugt eine `AttributedString` mit
/// Formatierung, Mentions und klickbaren Links. Bewusst von den Foundation-DTOs
/// getrennt (braucht den SwiftUI-Attribut-Scope).
extension ADFNode {
    func attributedText() -> AttributedString {
        var result = AttributedString()
        build(into: &result)
        // Durch die Absatz-Logik entstandene Trailing-Newlines entfernen.
        while let last = result.characters.last, last == "\n" {
            let lastIndex = result.index(result.endIndex, offsetByCharacters: -1)
            result.removeSubrange(lastIndex..<result.endIndex)
        }
        return result
    }

    private func build(into result: inout AttributedString) {
        var skipContent = false
        switch type {
        case "text":
            if let text {
                result += styledText(text)
            }
        case "mention":
            var piece = AttributedString(attrs?.text ?? "")
            piece.foregroundColor = .accentColor
            piece.font = .body.weight(.semibold)
            result += piece
        case "emoji":
            result += AttributedString(attrs?.text ?? attrs?.shortName ?? "")
        case "hardBreak":
            result += AttributedString("\n")
        case "codeBlock":
            let code = content?.map { $0.plainText() }.joined(separator: "\n") ?? ""
            var piece = AttributedString(code)
            piece.font = .system(.body, design: .monospaced)
            result += piece
            result += AttributedString("\n")
            skipContent = true
        default:
            break
        }
        if !skipContent {
            content?.forEach { $0.build(into: &result) }
        }
        if type == "paragraph" {
            result += AttributedString("\n")
        }
    }

    private func styledText(_ text: String) -> AttributedString {
        var piece = AttributedString(text)
        for mark in marks ?? [] {
            switch mark.type {
            case "strong":
                piece.font = .body.bold()
            case "em":
                piece.font = .body.italic()
            case "code":
                piece.font = .system(.body, design: .monospaced)
            case "link":
                if let href = mark.attrs?.href ?? mark.attrs?.url, let url = URL(string: href) {
                    piece.link = url
                    piece.foregroundColor = .accentColor
                    piece.underlineStyle = .single
                }
            default:
                break
            }
        }
        return piece
    }
}

/// Dekodiert gespeichertes Roh-ADF (JSON) zu einer `AttributedString`.
func renderADF(_ json: String?) -> AttributedString? {
    guard let json,
          let data = json.data(using: .utf8),
          let node = try? JSONDecoder().decode(ADFNode.self, from: data) else {
        return nil
    }
    let text = node.attributedText()
    return text.characters.isEmpty ? nil : text
}
