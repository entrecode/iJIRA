import AppKit
import SwiftUI

/// NSTextView-Wrapper mit Live-Markdown-Syntaxfärbung.
/// Unterstützt dieselbe Syntax wie `markdownToADFBody`: ```blocks```, `code`,
/// **fett**, *kursiv*.
struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String

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

        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tv = scrollView.documentView as? NSTextView else { return }
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
        }
    }
}

// MARK: - Styling

private enum MDPattern {
    static let codeBlock = try! NSRegularExpression(
        pattern: "```[\\s\\S]*?```", options: .dotMatchesLineSeparators)
    static let inlineCode = try! NSRegularExpression(pattern: "`[^`\n]+`")
    static let bold = try! NSRegularExpression(pattern: "\\*\\*[^\\*\n]+\\*\\*")
    static let italic = try! NSRegularExpression(pattern: "(?<!\\*)\\*(?!\\*)[^\\*\n]+\\*(?!\\*)")
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

    storage.endEditing()
}
