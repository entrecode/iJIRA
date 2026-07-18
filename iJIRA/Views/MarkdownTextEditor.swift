import AppKit
import SwiftUI

/// Steuer-Objekt für den Editor: erlaubt der SwiftUI-Seite, an der aktuellen
/// Mention-Query Text zu ersetzen (Auswahl aus der Vorschlagsliste).
@MainActor
final class MarkdownEditorController {
    fileprivate weak var textView: NSTextView?

    /// Ersetzt die aktive `@…`-Query vor dem Cursor durch das Mention-Token.
    func insertMention(_ user: UserDTO) {
        guard let tv = textView, let accountId = user.accountId,
              let queryRange = MarkdownTextEditor.mentionQueryRange(in: tv) else { return }
        let token = "@[\(user.displayName ?? "?")](\(accountId)) "
        if tv.shouldChangeText(in: queryRange, replacementString: token) {
            tv.replaceCharacters(in: queryRange, with: token)
            tv.didChangeText()
        }
        tv.window?.makeFirstResponder(tv)
    }
}

/// NSTextView-Wrapper mit Live-Markdown-Syntaxfärbung.
/// Unterstützt dieselbe Syntax wie `markdownToADFBody`: ```blocks```, `code`,
/// **fett**, *kursiv*, # Überschriften, Listen, @[Mention](id), [Link](url).
struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    /// Optional: Controller für Mention-Einfügung.
    var controller: MarkdownEditorController? = nil
    /// Meldet die aktive Mention-Query hinter „@" am Cursor (nil = keine).
    var onMentionQuery: ((String?) -> Void)? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let tv = scrollView.documentView as? NSTextView else { return scrollView }

        tv.delegate = context.coordinator
        tv.isRichText = true
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.font = .systemFont(ofSize: NSFont.systemFontSize)
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.drawsBackground = false

        controller?.textView = tv

        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tv = scrollView.documentView as? NSTextView else { return }
        controller?.textView = tv
        guard tv.string != text else { return }

        let saved = tv.selectedRange()
        tv.string = text
        applyMarkdownStyling(to: tv)
        let clamped = NSRange(location: min(saved.location, (text as NSString).length), length: 0)
        tv.setSelectedRange(clamped)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextEditor
        init(_ parent: MarkdownTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let saved = tv.selectedRange()
            parent.text = tv.string
            applyMarkdownStyling(to: tv)
            tv.setSelectedRange(saved)
            reportMentionQuery(tv)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            reportMentionQuery(tv)
        }

        private func reportMentionQuery(_ tv: NSTextView) {
            guard let handler = parent.onMentionQuery else { return }
            if let range = MarkdownTextEditor.mentionQueryRange(in: tv) {
                let query = (tv.string as NSString).substring(with: range)
                handler(String(query.dropFirst())) // ohne "@"
            } else {
                handler(nil)
            }
        }
    }

    /// Findet die aktive Mention-Query vor dem Cursor: ein "@" an Wortgrenze,
    /// gefolgt von Namenszeichen (max. 30) bis zum Cursor. Bereits fertige
    /// Tokens (`@[…](…)`) matchen nicht.
    static func mentionQueryRange(in tv: NSTextView) -> NSRange? {
        let selection = tv.selectedRange()
        guard selection.length == 0 else { return nil }
        let string = tv.string as NSString
        let caret = selection.location
        let start = max(0, caret - 31)
        func character(at location: Int) -> Character {
            guard let scalar = UnicodeScalar(string.character(at: location)) else { return " " }
            return Character(scalar)
        }
        var atLocation: Int?
        var index = caret - 1
        while index >= start {
            let ch = character(at: index)
            if ch == "@" {
                atLocation = index
                break
            }
            // Nur Namenszeichen zwischen @ und Cursor zulassen.
            if !(ch.isLetter || ch.isNumber || ch == " " || ch == "-" || ch == ".") {
                return nil
            }
            index -= 1
        }
        guard let at = atLocation else { return nil }
        // "@" muss am Anfang oder nach einem Nicht-Wortzeichen stehen.
        if at > 0 {
            let before = character(at: at - 1)
            if before.isLetter || before.isNumber { return nil }
        }
        // Fertiges Token? ("@[" direkt nach dem @)
        if at + 1 < string.length, string.character(at: at + 1) == UInt16(UInt8(ascii: "[")) {
            return nil
        }
        return NSRange(location: at, length: caret - at)
    }
}

// MARK: - Styling

private enum MDPattern {
    static let codeBlock = try! NSRegularExpression(
        pattern: "```[\\s\\S]*?```", options: .dotMatchesLineSeparators)
    static let inlineCode = try! NSRegularExpression(pattern: "`[^`\n]+`")
    static let bold = try! NSRegularExpression(pattern: "\\*\\*[^\\*\n]+\\*\\*")
    static let italic = try! NSRegularExpression(pattern: "(?<!\\*)\\*(?!\\*)[^\\*\n]+\\*(?!\\*)")
    static let mention = try! NSRegularExpression(pattern: "@\\[[^\\]\n]+\\]\\([^)\n]+\\)")
    static let heading = try! NSRegularExpression(pattern: "^#{1,6} .*$", options: .anchorsMatchLines)
    static let listMarker = try! NSRegularExpression(pattern: "^(- |\\* |\\d+\\. |> )", options: .anchorsMatchLines)
}

private func applyMarkdownStyling(to tv: NSTextView) {
    guard let storage = tv.textStorage else { return }
    let str = storage.string
    let full = NSRange(str.startIndex..., in: str)
    let baseFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)

    storage.beginEditing()

    // Reset
    storage.setAttributes([.font: baseFont, .foregroundColor: NSColor.labelColor], range: full)

    // Code blocks
    MDPattern.codeBlock.enumerateMatches(in: str, range: full) { m, _, _ in
        guard let r = m?.range else { return }
        storage.addAttributes([
            .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .foregroundColor: NSColor.systemOrange,
            .backgroundColor: NSColor.labelColor.withAlphaComponent(0.05)
        ], range: r)
    }

    // Inline code
    MDPattern.inlineCode.enumerateMatches(in: str, range: full) { m, _, _ in
        guard let r = m?.range else { return }
        storage.addAttributes([
            .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .foregroundColor: NSColor.systemOrange,
            .backgroundColor: NSColor.labelColor.withAlphaComponent(0.05)
        ], range: r)
    }

    // Bold
    MDPattern.bold.enumerateMatches(in: str, range: full) { m, _, _ in
        guard let r = m?.range else { return }
        storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize), range: r)
    }

    // Italic
    MDPattern.italic.enumerateMatches(in: str, range: full) { m, _, _ in
        guard let r = m?.range else { return }
        let italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
        storage.addAttribute(.font, value: italicFont, range: r)
    }

    // Mentions (@[Name](id))
    MDPattern.mention.enumerateMatches(in: str, range: full) { m, _, _ in
        guard let r = m?.range else { return }
        storage.addAttributes([
            .foregroundColor: NSColor.controlAccentColor,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
        ], range: r)
    }

    // Überschriften
    MDPattern.heading.enumerateMatches(in: str, range: full) { m, _, _ in
        guard let r = m?.range else { return }
        storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize + 1), range: r)
    }

    // Listen-/Zitat-Marker dezent hervorheben
    MDPattern.listMarker.enumerateMatches(in: str, range: full) { m, _, _ in
        guard let r = m?.range else { return }
        storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: r)
    }

    storage.endEditing()
}
