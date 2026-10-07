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
            return paragraphView(node.content ?? [])

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

        // Der Zitat-Balken liegt als `overlay` hinter dem Text, nicht als
        // HStack-Geschwister daneben. Grund: `RoundedRectangle` ist eine Shape
        // und damit in der Höhe unbegrenzt gierig — `.frame(width: 3)` deckelt
        // nur die Breite. Als Geschwister im Block-`VStack` trieb er dessen
        // Höhenbedarf ins Unendliche; der VStack musste die verfügbare Höhe
        // dann verteilen und quetschte die anderen Blöcke. Ein gequetschter
        // `Text` wrappt nicht, sondern kürzt auf eine Zeile mit „…" — sichtbar
        // vor allem an Listen (viel Text pro Block). Im `overlay` bekommt der
        // Balken die Höhe des Inhalts und beeinflusst das Layout gar nicht.
        case "blockquote":
            return AnyView(
                VStack(alignment: .leading, spacing: 6) {
                    blockViews(node.content ?? [])
                }
                // 3 pt Balken + 8 pt Abstand — entspricht dem früheren HStack.
                .padding(.leading, 11)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor.opacity(0.5))
                        .frame(width: 3)
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
            return tableView(node)

        case "taskList", "decisionList":
            return AnyView(
                VStack(alignment: .leading, spacing: 4) {
                    blockViews(node.content ?? [])
                }
                .padding(.leading, 2)
            )

        case "taskItem", "decisionItem":
            let done = node.attrs?.state == "DONE"
            let icon = node.type == "decisionItem"
                ? "arrow.triangle.branch"
                : (done ? "checkmark.square.fill" : "square")
            return AnyView(
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: icon)
                        .foregroundStyle(done ? Color.accentColor : .secondary)
                        .frame(minWidth: 16, alignment: .trailing)
                    paragraphView(node.content ?? [])
                        .foregroundStyle(done ? .secondary : .primary)
                }
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
        let start = node.attrs?.order ?? 1
        return AnyView(
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ordered ? "\(start + index)." : "•")
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

    // MARK: - Tabellen

    /// Tabelle mit Rahmen, Kopfzeilen-Hintergrund und verbundenen Zellen.
    /// Die Positionen (inkl. Zeilen-/Spaltenverbund) werden hier vorab
    /// berechnet; die Größen verteilt `ADFTableLayout`.
    private func tableView(_ node: ADFNode) -> AnyView {
        let cells = ADFTableLayout.positionedCells(node)
        guard !cells.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(
            ADFTableLayout {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, entry in
                    tableCell(entry.cell)
                        .layoutValue(key: ADFTableCellPosition.self, value: entry.position)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.35), lineWidth: 1))
        )
    }

    private func tableCell(_ cell: ADFNode) -> some View {
        let isHeader = cell.type == "tableHeader"
        return VStack(alignment: .leading, spacing: 6) {
            blockViews(cell.content ?? [])
        }
        .fontWeight(isHeader ? .semibold : nil)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        // Füllt die vom Layout zugeteilte Fläche, damit Hintergrund und
        // Rahmen bündig sind. Unbedenklich, weil `ADFTableLayout` beim
        // Messen nie eine endliche Höhe vorschlägt (vgl. Zitat-Kommentar).
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(cellBackground(cell, isHeader: isHeader))
        .overlay(Rectangle().stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
    }

    private func cellBackground(_ cell: ADFNode, isHeader: Bool) -> Color {
        if let hex = cell.attrs?.background, let color = Color(adfHex: hex) {
            return color.opacity(0.5)
        }
        return isHeader ? Color.secondary.opacity(0.12) : .clear
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

    // MARK: - Absätze (Zeilen, Links als Chip)

    /// Ein Absatz wird an seinen `hardBreak`s in Zeilen geschnitten. Zeilen,
    /// die nur aus einem Link bestehen, werden als Chip gerendert — alle
    /// anderen als Text wie bisher.
    ///
    /// Grund für den Chip: Ein Link in einem `AttributedString` feuert nur bei
    /// einem bewegungsfreien Klick. Gemessen mit synthetischen Klicks à 6 px
    /// Bewegung: Text-Link 1 von 10, `Link`-View 10 von 10 — von Hand ist der
    /// Text-Link also praktisch nicht zu treffen.
    ///
    /// Der Schnitt auf Zeilenebene (nicht auf Absatzebene) ist nötig, weil
    /// Jira Smart Links gern per `hardBreak` an einen Textabsatz hängt statt
    /// einen eigenen Absatz anzulegen.
    private func paragraphView(_ nodes: [ADFNode]) -> AnyView {
        let lines = splitAtHardBreaks(nodes)
        let blocks: [AnyView] = lines.compactMap { line in
            if let link = soleLink(in: line) {
                return AnyView(LinkChip(url: link.url, label: link.label))
            }
            let text = inlineText(line)
            if text.characters.isEmpty { return nil }
            return AnyView(Text(text).textSelection(.enabled))
        }
        guard !blocks.isEmpty else { return AnyView(EmptyView()) }
        if blocks.count == 1 { return blocks[0] }
        return AnyView(
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    block
                }
            }
        )
    }

    private func splitAtHardBreaks(_ nodes: [ADFNode]) -> [[ADFNode]] {
        var lines: [[ADFNode]] = [[]]
        for node in nodes {
            if node.type == "hardBreak" {
                lines.append([])
            } else {
                lines[lines.count - 1].append(node)
            }
        }
        return lines
    }

    /// Der einzige inhaltstragende Knoten der Zeile ist ein Link. Reine
    /// Leerzeichen-Textknoten zählen nicht mit; Jira legt um Smart Links gern
    /// welche ab.
    private func soleLink(in nodes: [ADFNode]) -> (url: URL, label: String)? {
        let meaningful = nodes.filter { node in
            guard node.type == "text" else { return true }
            return !(node.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard meaningful.count == 1, let node = meaningful.first else { return nil }

        if node.type == "inlineCard", let raw = node.attrs?.url, let url = URL(string: raw) {
            return (url, JiraKeyParser.directKey(from: raw) ?? url.host ?? raw)
        }
        if node.type == "text",
           let mark = node.marks?.first(where: { $0.type == "link" }),
           let raw = mark.attrs?.href ?? mark.attrs?.url,
           let url = URL(string: raw) {
            let text = (node.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return (url, text.isEmpty ? (url.host ?? raw) : text)
        }
        return nil
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
                // `directKey` statt `key`: letzteres sucht das Key-Muster
                // irgendwo im String und trifft dann auch UUIDs in Fremd-URLs
                // („…/f7aa484d-744d-4c0b-…" → „F7AA484D-744"). Jira zeigt hier
                // den Seitentitel; den haben wir nicht, also der Host.
                let label = JiraKeyParser.directKey(from: urlString) ?? url.host ?? urlString
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

// MARK: - Tabellen-Layout

/// Lage einer Zelle im Tabellenraster (nach Auflösung von Zeilen-/Spaltenverbund).
struct ADFTableCellPosition: LayoutValueKey {
    static let defaultValue = Position(row: 0, column: 0, rowSpan: 1, columnSpan: 1)

    struct Position: Equatable {
        let row: Int
        let column: Int
        let rowSpan: Int
        let columnSpan: Int
    }
}

/// Raster-Layout für ADF-Tabellen. Spalten bekommen ihre natürliche Breite;
/// passt die Tabelle nicht, wird der Platz „wasserstandsartig" verteilt:
/// schmale Spalten behalten ihre Breite, breite teilen sich den Rest und
/// brechen um. Zeilenhöhe = höchste Zelle.
///
/// Eine Mindestbreite pro Spalte lässt sich nicht messen: mit Breite 0
/// gemessen bricht `Text` zeichen-, nicht wortweise um.
///
/// Gemessen wird immer mit unbestimmter Höhe — so bleiben die Zellen, die
/// mit `maxHeight: .infinity` ihre Fläche füllen, beim Messen harmlos.
struct ADFTableLayout: Layout {
    var minColumnWidth: CGFloat = 56

    /// Zellen der Tabelle mit ihrer Rasterposition. Von Zeilenverbund
    /// belegte Plätze werden übersprungen — wie Jira es erwartet: Folgezeilen
    /// lassen die überdeckten Zellen einfach weg.
    static func positionedCells(_ table: ADFNode) -> [(cell: ADFNode, position: ADFTableCellPosition.Position)] {
        var result: [(ADFNode, ADFTableCellPosition.Position)] = []
        var occupied = Set<[Int]>()
        let rows = (table.content ?? []).filter { $0.type == "tableRow" }
        for (rowIndex, row) in rows.enumerated() {
            var column = 0
            for cell in row.content ?? [] where cell.type == "tableCell" || cell.type == "tableHeader" {
                while occupied.contains([rowIndex, column]) { column += 1 }
                let rowSpan = max(1, min(cell.attrs?.rowspan ?? 1, rows.count - rowIndex))
                let columnSpan = max(1, cell.attrs?.colspan ?? 1)
                for r in rowIndex..<(rowIndex + rowSpan) {
                    for c in column..<(column + columnSpan) { occupied.insert([r, c]) }
                }
                result.append((cell, .init(row: rowIndex, column: column,
                                           rowSpan: rowSpan, columnSpan: columnSpan)))
                column += columnSpan
            }
        }
        return result
    }

    struct Metrics {
        var columnWidths: [CGFloat]
        var rowHeights: [CGFloat]

        func x(_ column: Int) -> CGFloat { columnWidths.prefix(column).reduce(0, +) }
        func y(_ row: Int) -> CGFloat { rowHeights.prefix(row).reduce(0, +) }
        func width(_ p: ADFTableCellPosition.Position) -> CGFloat {
            columnWidths[p.column..<(p.column + p.columnSpan)].reduce(0, +)
        }
        func height(_ p: ADFTableCellPosition.Position) -> CGFloat {
            rowHeights[p.row..<(p.row + p.rowSpan)].reduce(0, +)
        }
    }

    func makeCache(subviews: Subviews) -> [CGFloat: Metrics] { [:] }

    func updateCache(_ cache: inout [CGFloat: Metrics], subviews: Subviews) {
        cache.removeAll()
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout [CGFloat: Metrics]) -> CGSize {
        let m = metrics(for: proposal.width, subviews: subviews, cache: &cache)
        return CGSize(width: m.columnWidths.reduce(0, +), height: m.rowHeights.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout [CGFloat: Metrics]) {
        let m = metrics(for: bounds.width, subviews: subviews, cache: &cache)
        for subview in subviews {
            let p = subview[ADFTableCellPosition.self]
            subview.place(at: CGPoint(x: bounds.minX + m.x(p.column), y: bounds.minY + m.y(p.row)),
                          proposal: ProposedViewSize(width: m.width(p), height: m.height(p)))
        }
    }

    private func metrics(for width: CGFloat?, subviews: Subviews,
                         cache: inout [CGFloat: Metrics]) -> Metrics {
        let key = width ?? -1
        if let cached = cache[key] { return cached }
        let positions = subviews.map { $0[ADFTableCellPosition.self] }
        let columns = positions.map { $0.column + $0.columnSpan }.max() ?? 0
        let rows = positions.map { $0.row + $0.rowSpan }.max() ?? 0

        // Natürliche (einzeilige) Spaltenbreiten aus den nicht verbundenen Zellen.
        var ideal = Array(repeating: CGFloat(24), count: columns)
        for (subview, p) in zip(subviews, positions) where p.columnSpan == 1 {
            ideal[p.column] = max(ideal[p.column], ceil(subview.sizeThatFits(.unspecified).width))
        }
        let widths = distribute(ideal: ideal, available: width)

        var heights = Array(repeating: CGFloat(0), count: rows)
        var metrics = Metrics(columnWidths: widths, rowHeights: heights)
        func measure(_ subview: LayoutSubview, _ p: ADFTableCellPosition.Position) -> CGFloat {
            ceil(subview.sizeThatFits(ProposedViewSize(width: metrics.width(p), height: nil)).height)
        }
        for (subview, p) in zip(subviews, positions) where p.rowSpan == 1 {
            heights[p.row] = max(heights[p.row], measure(subview, p))
        }
        metrics.rowHeights = heights
        // Zeilenverbund: fehlende Höhe der letzten überdeckten Zeile zuschlagen.
        for (subview, p) in zip(subviews, positions) where p.rowSpan > 1 {
            let missing = measure(subview, p) - metrics.height(p)
            if missing > 0 { metrics.rowHeights[p.row + p.rowSpan - 1] += missing }
        }
        cache[key] = metrics
        return metrics
    }

    private func distribute(ideal: [CGFloat], available: CGFloat?) -> [CGFloat] {
        guard let available, ideal.reduce(0, +) > available else { return ideal }
        var widths = ideal
        var open = Array(ideal.indices)
        var remaining = available
        while !open.isEmpty {
            let share = remaining / CGFloat(open.count)
            let fitting = open.filter { ideal[$0] <= share }
            if fitting.isEmpty {
                for column in open { widths[column] = max(share, minColumnWidth) }
                break
            }
            for column in fitting {
                widths[column] = ideal[column]
                remaining -= ideal[column]
            }
            open.removeAll { fitting.contains($0) }
        }
        return widths
    }
}

extension Color {
    /// ADF-Zellfarben kommen als "#rrggbb".
    init?(adfHex: String) {
        let hex = adfHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
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

/// Link als klickbarer Chip. Bewusst ein `Link`-View und kein Link in einem
/// `AttributedString`: letzterer verlangt einen bewegungsfreien Klick und ist
/// von Hand kaum zu treffen (gemessen 1 von 10 gegen 10 von 10).
/// Der Tooltip zeigt die vollständige URL — im Chip steht nur Key bzw. Host.
private struct LinkChip: View {
    let url: URL
    let label: String

    @State private var hovering = false

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 5) {
                Image(systemName: "link").font(.caption2)
                Text(label).font(.callout.weight(.medium))
            }
            .foregroundStyle(.tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(hovering ? 0.18 : 0.1), in: Capsule())
            // Großzügige, unsichtbare Trefferfläche. Nötig wegen einer
            // Hit-Test-Anomalie in dieser Ansicht: gemessen reagiert nur das
            // obere Drittel bis knapp die Hälfte des Frames (aktive Zone
            // 715–724 pt bei einem Chip, der 713,5–736,3 pt einnimmt). Die
            // Ursache ist nicht gefunden; da die Zone anteilig mitwächst,
            // macht ein größerer Frame den Chip zuverlässig treffbar.
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(url.absoluteString)
    }
}
