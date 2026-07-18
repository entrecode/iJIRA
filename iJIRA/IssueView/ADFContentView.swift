import AppKit
import SwiftUI

/// Block-basierte ADF-Darstellung für die Issue-Detail-Ansicht: Absätze,
/// Überschriften, Listen, Code, Zitate, Panels und — via Attachment-Zuordnung —
/// eingebettete Bilder/Videos. Deutlich vollständiger als die kompakte
/// `attributedText()`-Variante der Menüleiste.
struct ADFContentView: View {
    let document: ADFNode
    /// Media-alt-Text (Dateiname) → Attachment.
    var resolveAttachment: (String?) -> AttachmentDTO? = { _ in nil }
    /// Thumbnail-Zugriff (löst asynchrones Laden aus, liefert Cache-Treffer).
    var thumbnail: (AttachmentDTO) -> NSImage? = { _ in nil }
    var onOpenAttachment: (AttachmentDTO) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            blockViews(document.content ?? [])
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Blöcke

    private func blockViews(_ nodes: [ADFNode]) -> AnyView {
        AnyView(
            ForEach(Array(nodes.enumerated()), id: \.offset) { _, node in
                blockView(node)
            }
        )
    }

    private func blockView(_ node: ADFNode) -> AnyView {
        switch node.type {
        case "paragraph":
            let text = inlineText(node.content ?? [])
            if text.characters.isEmpty { return AnyView(EmptyView()) }
            return AnyView(Text(text).textSelection(.enabled))

        case "heading":
            let text = inlineText(node.content ?? [])
            let level = node.attrs?.level ?? 3
            return AnyView(
                Text(text)
                    .font(headingFont(level))
                    .textSelection(.enabled)
                    .padding(.top, 4)
            )

        case "codeBlock":
            let code = node.content?.map { $0.plainText() }.joined(separator: "\n") ?? ""
            return AnyView(
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.6),
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary, lineWidth: 1))
            )

        case "blockquote":
            return AnyView(
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor.opacity(0.5))
                        .frame(width: 3)
                    VStack(alignment: .leading, spacing: 6) {
                        blockViews(node.content ?? [])
                    }
                }
            )

        case "bulletList":
            return listView(node, ordered: false)

        case "orderedList":
            return listView(node, ordered: true)

        case "rule":
            return AnyView(Divider())

        case "mediaSingle", "mediaGroup":
            return mediaViews(node.content ?? [])

        case "media":
            return mediaViews([node])

        case "panel":
            let tint = panelTint(node.attrs?.type)
            return AnyView(
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: tint.icon).foregroundStyle(tint.color)
                    VStack(alignment: .leading, spacing: 6) {
                        blockViews(node.content ?? [])
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(tint.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            )

        case "table":
            return AnyView(
                Label("Tabelle — bitte im Web ansehen", systemImage: "tablecells")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            )

        default:
            // Unbekannte Container transparent durchreichen (expand, doc, …).
            if let content = node.content, !content.isEmpty {
                return blockViews(content)
            }
            return AnyView(EmptyView())
        }
    }

    private func listView(_ node: ADFNode, ordered: Bool) -> AnyView {
        let items = node.content ?? []
        return AnyView(
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ordered ? "\(index + 1)." : "•")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 16, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 4) {
                            blockViews(item.content ?? [])
                        }
                    }
                }
            }
            .padding(.leading, 2)
        )
    }

    // MARK: - Media

    private func mediaViews(_ nodes: [ADFNode]) -> AnyView {
        let mediaNodes = nodes.filter { $0.type == "media" }
        guard !mediaNodes.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(
            FlowLayoutLite(spacing: 8) {
                ForEach(Array(mediaNodes.enumerated()), id: \.offset) { _, media in
                    mediaView(media)
                }
            }
        )
    }

    private func mediaView(_ node: ADFNode) -> AnyView {
        let alt = node.attrs?.alt
        guard let attachment = resolveAttachment(alt) else {
            return AnyView(
                Label(alt ?? "Anhang", systemImage: "paperclip")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.quaternary.opacity(0.3), in: Capsule())
            )
        }
        return AnyView(
            AttachmentTile(attachment: attachment,
                           image: thumbnail(attachment),
                           onOpen: { onOpenAttachment(attachment) })
        )
    }

    // MARK: - Inline

    private func inlineText(_ nodes: [ADFNode]) -> AttributedString {
        var result = AttributedString()
        for node in nodes {
            appendInline(node, to: &result)
        }
        return result
    }

    private func appendInline(_ node: ADFNode, to result: inout AttributedString) {
        switch node.type {
        case "text":
            result += styledInline(node)
        case "mention":
            var piece = AttributedString(node.attrs?.text ?? "@?")
            piece.foregroundColor = .accentColor
            piece.font = .body.weight(.semibold)
            result += piece
        case "emoji":
            result += AttributedString(node.attrs?.text ?? node.attrs?.shortName ?? "")
        case "hardBreak":
            result += AttributedString("\n")
        case "inlineCard":
            if let urlString = node.attrs?.url, let url = URL(string: urlString) {
                let label = JiraKeyParser.key(from: urlString) ?? url.host ?? urlString
                var piece = AttributedString(label)
                piece.link = url
                piece.foregroundColor = .accentColor
                piece.font = .body.weight(.medium)
                piece.backgroundColor = Color.accentColor.opacity(0.1)
                result += piece
            }
        case "status":
            var piece = AttributedString(" \(node.attrs?.text ?? "?") ")
            piece.font = .callout.weight(.semibold)
            piece.foregroundColor = .secondary
            piece.backgroundColor = Color.secondary.opacity(0.15)
            result += piece
        default:
            node.content?.forEach { appendInline($0, to: &result) }
        }
    }

    private func styledInline(_ node: ADFNode) -> AttributedString {
        var piece = AttributedString(node.text ?? "")
        var isBold = false
        var isItalic = false
        for mark in node.marks ?? [] {
            switch mark.type {
            case "strong": isBold = true
            case "em": isItalic = true
            case "code":
                piece.font = .system(.body, design: .monospaced)
                piece.backgroundColor = Color.primary.opacity(0.06)
            case "link":
                if let href = mark.attrs?.href ?? mark.attrs?.url, let url = URL(string: href) {
                    piece.link = url
                    piece.foregroundColor = .accentColor
                    piece.underlineStyle = .single
                }
            case "strike":
                piece.strikethroughStyle = .single
            default:
                break
            }
        }
        if isBold && isItalic { piece.font = .body.bold().italic() }
        else if isBold { piece.font = .body.bold() }
        else if isItalic { piece.font = .body.italic() }
        return piece
    }

    // MARK: - Helpers

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title.weight(.semibold)
        case 2: return .title2.weight(.semibold)
        case 3: return .title3.weight(.semibold)
        default: return .headline
        }
    }

    private func panelTint(_ type: String?) -> (color: Color, icon: String) {
        switch type {
        case "warning": return (.orange, "exclamationmark.triangle")
        case "error": return (.red, "xmark.octagon")
        case "success": return (.green, "checkmark.circle")
        case "note": return (.purple, "note.text")
        default: return (.blue, "info.circle")
        }
    }
}

// MARK: - Attachment-Kachel

/// Vorschau-Kachel eines Anhangs: Bild-Thumbnail, wenn verfügbar, sonst
/// Datei-Chip. Klick lädt herunter und öffnet in der Standard-App.
struct AttachmentTile: View {
    let attachment: AttachmentDTO
    let image: NSImage?
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            if let image {
                ZStack(alignment: .center) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: 240, maxHeight: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary, lineWidth: 1))
                    if attachment.isVideo {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.white.opacity(0.9))
                            .shadow(radius: 4)
                    }
                }
            } else {
                Label(attachment.filename, systemImage: symbolName)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: 240, alignment: .leading)
                    .background(.quaternary.opacity(0.3), in: Capsule())
            }
        }
        .buttonStyle(.plain)
        .help(attachment.filename)
    }

    private var symbolName: String {
        if attachment.isVideo { return "film" }
        if attachment.isImage { return "photo" }
        if attachment.mimeType == "application/pdf" { return "doc.richtext" }
        return "paperclip"
    }
}

// MARK: - Einfaches Flow-Layout

/// Minimalistisches Umbruch-Layout für Media-Kacheln (macOS 14 `Layout`).
struct FlowLayoutLite: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
