import SwiftUI
import UniformTypeIdentifiers

/// Eine Status-Spalte des Boards. Drop-Ziel für Issue-Karten (DnD-Statuswechsel).
struct BoardColumnView: View {
    @Bindable var store: BoardStore
    let column: BoardStore.ColumnSnapshot

    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(column.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .kerning(0.3)
                Text("\(column.issues.count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary.opacity(0.5), in: Capsule())
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(column.issues) { issue in
                        IssueCardView(issue: issue)
                            .draggable(issue.key)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .frame(width: 264)
        .frame(maxHeight: .infinity, alignment: .top)
        .panelFill(.quaternary, base: dropTargeted ? 0.4 : 0.14,
                   in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(dropTargeted ? Color.accentColor : .clear, lineWidth: 2)
        )
        .dropDestination(for: String.self) { keys, _ in
            guard let key = keys.first else { return false }
            Task { await store.move(issueKey: key, toColumn: column.name) }
            return true
        } isTargeted: { dropTargeted = $0 }
    }
}

/// Issue-Karte: kopierbarer Key, Summary, Typ/Priorität/Alter.
/// Klick → Detailview (⌥-Klick → Einzelfenster), ziehbar für Statuswechsel.
struct IssueCardView: View {
    let issue: BoardIssueDTO
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                IssueTypeIcon(typeName: issue.fields.issuetype?.name)
                CopyableKeyLabel(key: issue.key)
                Spacer(minLength: 0)
                PriorityIcon(priorityName: issue.fields.priority?.name)
            }
            Text(issue.fields.summary)
                .font(.callout)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let updated = issue.updatedDate {
                RelativeTimeText(date: updated)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .panelFill(.background, base: hovering ? 0.8 : 0.45,
                   in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(hovering ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.06),
                        lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            IssueWindowManager.shared.open(issueKey: issue.key)
        }
    }
}

// MARK: - Kleinteile

/// Key mit Mini-Copy-Button (kompakter als der große IssueKeyChip).
struct CopyableKeyLabel: View {
    let key: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(.tint)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(key, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9))
                    .foregroundStyle(copied ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .help("Key kopieren")
        }
    }
}

/// Issue-Typ als natives SF-Symbol (Jiras Icon-URLs sind SVG — statt sie zu
/// laden, mappen wir auf Symbole: schneller und passt zum System-Look).
struct IssueTypeIcon: View {
    let typeName: String?

    var body: some View {
        Image(systemName: symbol.name)
            .font(.caption)
            .foregroundStyle(symbol.color)
            .help(typeName ?? "")
    }

    private var symbol: (name: String, color: Color) {
        switch typeName?.lowercased() {
        case "bug": return ("ladybug.fill", .red)
        case "story": return ("bookmark.fill", .green)
        case "epic": return ("bolt.fill", .purple)
        case "task", "aufgabe": return ("checkmark.square.fill", .blue)
        case "sub-task", "subtask", "unteraufgabe": return ("arrow.turn.down.right", .teal)
        default: return ("square.fill", .secondary)
        }
    }
}

/// Priorität als Symbol (gleiche Begründung wie IssueTypeIcon).
struct PriorityIcon: View {
    let priorityName: String?

    var body: some View {
        if let symbol {
            Image(systemName: symbol.name)
                .font(.caption)
                .foregroundStyle(symbol.color)
                .help(priorityName ?? "")
        }
    }

    private var symbol: (name: String, color: Color)? {
        switch priorityName?.lowercased() {
        case "highest": return ("chevron.up.2", .red)
        case "high", "hoch": return ("chevron.up", .orange)
        case "medium", "mittel": return nil // Normalfall — kein visuelles Rauschen
        case "low", "niedrig": return ("chevron.down", .cyan)
        case "lowest": return ("chevron.down.2", .blue)
        default: return nil
        }
    }
}
