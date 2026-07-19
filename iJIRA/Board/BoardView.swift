import SwiftUI

/// Board-Tab des Hauptfensters: oben das Sprint-Board (Spalten je
/// Board-Konfiguration), darunter — per Split verstellbar — die Liste der
/// eigenen offenen Issues außerhalb aktiver Sprints.
struct BoardView: View {
    @Bindable var store: BoardStore

    /// Höhe des Backlog-Bereichs — per Drag am Trenner verstellbar.
    /// (Kein VSplitView: NSSplitView zeichnet einen opaken Hintergrund und
    /// würde den transparenten Fenster-Backdrop verdecken.)
    @AppStorage("backlogHeight") private var backlogHeight = 240.0
    @State private var dragStartHeight: Double?

    var body: some View {
        if store.boards.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                boardArea
                    .frame(maxHeight: .infinity)
                splitHandle
                backlogArea
                    .frame(height: max(120, backlogHeight))
            }
        }
    }

    /// Schmaler, ziehbarer Trenner zwischen Board und Backlog.
    private var splitHandle: some View {
        ZStack {
            Divider()
            Capsule()
                .fill(.quaternary)
                .frame(width: 36, height: 4)
        }
        .frame(height: 9)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if dragStartHeight == nil { dragStartHeight = backlogHeight }
                    let proposed = (dragStartHeight ?? backlogHeight) - value.translation.height
                    backlogHeight = min(max(120, proposed), 600)
                }
                .onEnded { _ in dragStartHeight = nil }
        )
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Keine Boards", systemImage: "rectangle.split.3x1")
        } description: {
            Text(store.lastError ?? "Boards werden nach dem Verbinden automatisch geladen.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Board (oben)

    private var boardArea: some View {
        VStack(spacing: 0) {
            boardHeader
            if let snapshot = store.selectedSnapshot {
                if snapshot.columns.allSatisfy({ $0.issues.isEmpty }) {
                    boardEmptyHint(snapshot: snapshot)
                } else {
                    columnsView(snapshot: snapshot)
                }
            } else {
                ProgressView("Lade Board …")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var boardHeader: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(store.boards) { board in
                    Button {
                        store.selectedBoardId = board.id
                    } label: {
                        if board.id == store.selectedBoardId {
                            Label(store.boardDisplayNames[board.id] ?? board.name,
                                  systemImage: "checkmark")
                        } else {
                            Text(store.boardDisplayNames[board.id] ?? board.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(store.boardDisplayNames[store.selectedBoardId ?? -1]
                         ?? store.selectedBoard?.name ?? "Board wählen")
                        .font(.callout.weight(.semibold))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if let sprintName = store.selectedSnapshot?.sprintName {
                Text(sprintName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if store.isRefreshing {
                ProgressView().controlSize(.small)
            }
            if let error = store.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            } else if let fetchedAt = store.selectedSnapshot?.fetchedAt,
                      Date().timeIntervalSince(fetchedAt) > 300 {
                HStack(spacing: 3) {
                    Text("Stand")
                    RelativeTimeText(date: fetchedAt)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func boardEmptyHint(snapshot: BoardStore.BoardSnapshot) -> some View {
        ContentUnavailableView {
            Label(snapshot.sprintName == nil && store.selectedBoard?.type != "kanban"
                  ? "Kein aktiver Sprint"
                  : "Keine eigenen Issues",
                  systemImage: "checkmark.circle")
        } description: {
            Text(snapshot.sprintName == nil && store.selectedBoard?.type != "kanban"
                 ? "Dieses Board hat gerade keinen laufenden Sprint."
                 : "Dir ist hier aktuell nichts zugewiesen. 🎉")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func columnsView(snapshot: BoardStore.BoardSnapshot) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(snapshot.columns) { column in
                    BoardColumnView(store: store, column: column)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: - Backlog (unten)

    private var backlogArea: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Weitere offene Issues (\(store.backlog.count))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .kerning(0.4)
                Spacer()
                Text("Zugewiesen an dich, in keinem aktiven Sprint")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider().opacity(0.4)
            if store.backlog.isEmpty {
                Text("Nichts offen außerhalb der Sprints.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(store.backlog) { issue in
                            BacklogRow(issue: issue)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
        }
    }
}

// MARK: - Backlog-Zeile

private struct BacklogRow: View {
    let issue: BoardIssueDTO
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            IssueTypeIcon(typeName: issue.fields.issuetype?.name)
            CopyableKeyLabel(key: issue.key)
                .frame(minWidth: 92, alignment: .leading)
            Text(issue.fields.summary)
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let updated = issue.updatedDate {
                RelativeTimeText(date: updated)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let status = issue.fields.status {
                StatusBadge(status: StatusDTO(name: status.name ?? "?",
                                              statusCategory: status.statusCategory))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(hovering ? AnyShapeStyle(.quaternary.opacity(0.4)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            IssueWindowManager.shared.open(issueKey: issue.key)
        }
    }
}
