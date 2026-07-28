import SwiftUI

/// „Review & Plan"-Tab: Grundlage für Sprint Review und Planning.
///
/// Drei Blöcke untereinander, alle nach Thema (Epic) gruppiert:
/// 1. **Aktueller Sprint** — pro Thema die im Sprint geloggte Zeit, Themen
///    absteigend nach Zeit, Issues getrennt in „fertig" (die beiden hintersten
///    Board-Spalten) und „nicht fertig".
/// 2. **Nächster Sprint** — was geplant ist, ohne fertig/nicht-fertig.
/// 3. **Nicht eingeplant** — meine offenen Issues ohne Sprint.
struct ReviewView: View {
    @Bindable var store: ReviewStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            content
        }
        .task(id: store.loadTrigger) {
            await store.loadIfNeeded()
        }
    }

    // MARK: - Kopfzeile

    private var header: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(store.boardStore.boards) { board in
                    Button {
                        store.boardStore.selectedBoardId = board.id
                    } label: {
                        if board.id == store.boardStore.selectedBoardId {
                            Label(store.boardStore.boardDisplayNames[board.id] ?? board.name,
                                  systemImage: "checkmark")
                        } else {
                            Text(store.boardStore.boardDisplayNames[board.id] ?? board.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(store.boardStore.boardDisplayNames[store.boardStore.selectedBoardId ?? -1]
                         ?? "Board wählen")
                        .font(.callout.weight(.semibold))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if let name = store.selectedSnapshot?.sprintName {
                Text(name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if store.isLoading {
                ProgressView().controlSize(.small)
            }
            if let error = store.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            } else if let fetchedAt = store.selectedSnapshot?.fetchedAt {
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

    // MARK: - Inhalt

    @ViewBuilder
    private var content: some View {
        if let snapshot = store.selectedSnapshot {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    currentSprintSection(snapshot)
                    nextSprintSection(snapshot)
                    unplannedSection(snapshot)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: 1200, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        } else if store.isLoading {
            ProgressView("Lade Sprint-Daten …")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("Keine Daten", systemImage: "chart.bar.doc.horizontal")
            } description: {
                Text(store.lastError ?? "Board wählen und mit ⌘R laden.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - 1. Aktueller Sprint

    @ViewBuilder
    private func currentSprintSection(_ snapshot: ReviewStore.Snapshot) -> some View {
        let issues = snapshot.currentThemes.reduce(0) { $0 + $1.issueCount }
        let done = snapshot.currentThemes.reduce(0) { $0 + $1.doneRows.count }
        let rows = snapshot.currentThemes.reduce(0) { $0 + $1.rows.count }

        ReviewSection(
            title: "Aktueller Sprint",
            subtitle: snapshot.sprintName ?? "Kein laufender Sprint",
            detail: snapshot.currentThemes.isEmpty ? nil : [
                "\(snapshot.currentThemes.count) Themen",
                "\(issues) Issues",
                "\(done)/\(rows) fertig",
                Self.timeSummary(snapshot),
            ].joined(separator: " · "),
            hint: snapshot.doneColumnNames.isEmpty
                ? nil
                : "fertig = " + snapshot.doneColumnNames.joined(separator: " / ")
        ) {
            if snapshot.currentThemes.isEmpty {
                emptyHint(!snapshot.supportsSprints
                          ? "Dieses Board arbeitet ohne Sprints (Kanban) — für Review & Plan ein Scrum-Board wählen."
                          : snapshot.sprintName == nil
                          ? "Dieses Board hat gerade keinen laufenden Sprint."
                          : "Dir ist in diesem Sprint nichts zugewiesen. 🎉")
            } else {
                ForEach(snapshot.currentThemes) { theme in
                    // Ohne Zeitquelle wären die Spalten nur leere Striche.
                    ReviewThemeCard(theme: theme, splitDone: true,
                                    showTime: snapshot.timeSource != .none)
                }
            }
        }
    }

    // MARK: - 2. Nächster Sprint

    @ViewBuilder
    private func nextSprintSection(_ snapshot: ReviewStore.Snapshot) -> some View {
        ReviewSection(
            title: "Nächster Sprint",
            subtitle: snapshot.nextSprintName ?? "Kein geplanter Sprint",
            detail: snapshot.nextThemes.isEmpty ? nil : [
                "\(snapshot.nextThemes.count) Themen",
                "\(snapshot.nextThemes.reduce(0) { $0 + $1.issueCount }) Issues",
            ].joined(separator: " · "),
            hint: nil
        ) {
            if snapshot.nextThemes.isEmpty {
                emptyHint(!snapshot.supportsSprints
                          ? "Kanban-Board — keine Sprintplanung."
                          : snapshot.nextSprintName == nil
                          ? "Für dieses Board ist kein weiterer Sprint angelegt."
                          : "Dir ist für den nächsten Sprint noch nichts zugewiesen.")
            } else {
                ForEach(snapshot.nextThemes) { theme in
                    ReviewThemeCard(theme: theme, splitDone: false, showTime: false)
                }
            }
        }
    }

    // MARK: - 3. Nicht eingeplant

    @ViewBuilder
    private func unplannedSection(_ snapshot: ReviewStore.Snapshot) -> some View {
        ReviewSection(
            title: "Nicht eingeplant",
            subtitle: "Dir zugewiesen, offen, in keinem Sprint",
            detail: snapshot.unplannedThemes.isEmpty ? nil : [
                "\(snapshot.unplannedThemes.count) Themen",
                "\(snapshot.unplannedThemes.reduce(0) { $0 + $1.issueCount }) Issues",
            ].joined(separator: " · "),
            hint: nil
        ) {
            if snapshot.unplannedThemes.isEmpty {
                emptyHint("Nichts Offenes außerhalb der Sprints.")
            } else {
                ForEach(snapshot.unplannedThemes) { theme in
                    ReviewThemeCard(theme: theme, splitDone: false, showTime: false)
                }
            }
        }
    }

    /// „4h 15m geloggt (Harvest, 22.07.–28.07.)" — Summe, Quelle und Zeitraum
    /// in einem, damit im Review niemand über die Zahlen rätseln muss.
    private static func timeSummary(_ snapshot: ReviewStore.Snapshot) -> String {
        switch snapshot.timeSource {
        case .none:
            return "keine Zeiten (Harvest aktiv, aber kein Sprintzeitraum)"
        case .jiraTotals:
            return "\(snapshot.currentSeconds.asWorkDuration) gesamt (Jira, Sprintzeitraum unbekannt)"
        case .harvest, .jiraWorklogs:
            let source = snapshot.timeSource.label
            return "\(snapshot.currentSeconds.asWorkDuration) geloggt (\(source)\(range(snapshot)))"
        }
    }

    /// „, 22.07.–28.07." — der Zeitraum, über den die Zeiten gezählt wurden.
    /// Deployte Umgebungen laufen in UTC, deshalb explizit Europe/Berlin.
    private static func range(_ snapshot: ReviewStore.Snapshot) -> String {
        guard let start = snapshot.sprintStart, let end = snapshot.sprintEnd else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.timeZone = TimeZone(identifier: "Europe/Berlin")
        formatter.dateFormat = "dd.MM."
        return ", \(formatter.string(from: start))–\(formatter.string(from: end))"
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .padding(.vertical, 10)
    }
}

// MARK: - Abschnitt

/// Überschrift eines der drei Blöcke plus dessen Inhalt.
private struct ReviewSection<Content: View>: View {
    let title: String
    let subtitle: String
    let detail: String?
    let hint: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let hint {
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            content
        }
    }
}

// MARK: - Themen-Karte

/// Ein Thema (Epic) mit seinen Issues. Einklappbar, damit man im Review
/// abgearbeitete Themen aus dem Blick nehmen kann.
private struct ReviewThemeCard: View {
    let theme: ReviewStore.Theme
    /// Issues in „fertig" und „nicht fertig" trennen (nur im Review-Block).
    let splitDone: Bool
    let showTime: Bool

    @State private var collapsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !collapsed {
                Divider().opacity(0.3)
                VStack(alignment: .leading, spacing: 0) {
                    if splitDone {
                        group("Fertig", rows: theme.doneRows, tint: .green)
                        group("Nicht fertig", rows: theme.openRows, tint: .orange)
                    } else {
                        ForEach(theme.rows) { row in
                            ReviewRowView(row: row, showTime: showTime)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .panelFill(.background, base: 0.3, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary.opacity(0.5), lineWidth: 1))
    }

    private var header: some View {
        Button {
            collapsed.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)

                Text(theme.name)
                    .font(.headline)
                    .lineLimit(1)

                if let epicKey = theme.epicKey {
                    Text(epicKey)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary.opacity(0.5), in: Capsule())
                }

                Spacer(minLength: 8)

                if splitDone {
                    doneRatio
                }
                Text("\(theme.issueCount)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .help("Issues in diesem Thema")
                if showTime {
                    Text(theme.seconds.asWorkDuration)
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(theme.seconds > 0 ? .primary : .tertiary)
                        .frame(width: 78, alignment: .trailing)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// „3/5" plus schmaler Fortschrittsbalken — Fertigstand auf einen Blick.
    private var doneRatio: some View {
        let done = theme.doneRows.count
        let total = max(theme.rows.count, 1)
        return HStack(spacing: 6) {
            Text("\(done)/\(theme.rows.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Capsule()
                .fill(.quaternary)
                .frame(width: 44, height: 4)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Color.green)
                        .frame(width: 44 * Double(done) / Double(total), height: 4)
                }
        }
        .help("\(done) von \(theme.rows.count) fertig")
    }

    @ViewBuilder
    private func group(_ label: String, rows: [ReviewStore.Row], tint: Color) -> some View {
        if !rows.isEmpty {
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 5, height: 5)
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .kerning(0.4)
                Text("\(rows.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)

            ForEach(rows) { row in
                ReviewRowView(row: row, showTime: showTime)
            }
        }
    }
}

// MARK: - Issue-Zeile

/// Ein Issue als kompakte Zeile. Sub-Tasks sind eingeklappt (Badge mit Anzahl)
/// und lassen sich zum Vorlesen im Review aufklappen.
private struct ReviewRowView: View {
    let row: ReviewStore.Row
    let showTime: Bool

    @State private var hovering = false
    @State private var showSubtasks = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            mainRow
            if showSubtasks {
                ForEach(row.subtasks) { subtask in
                    subtaskRow(subtask)
                }
                .padding(.bottom, 3)
            }
        }
    }

    private var mainRow: some View {
        HStack(spacing: 9) {
            IssueTypeIcon(typeName: row.typeName)

            CopyableKeyLabel(key: row.key)
                .frame(minWidth: 92, alignment: .leading)

            Text(row.summary)
                .font(.callout)
                // Nur als Sammelzeile vorhanden (mir nicht zugewiesen): gedämpft.
                .foregroundStyle(row.isMine ? .primary : .secondary)
                .lineLimit(1)

            if !row.subtasks.isEmpty {
                Button {
                    showSubtasks.toggle()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: showSubtasks ? "chevron.down" : "chevron.right")
                            .font(.system(size: 7, weight: .semibold))
                        Text("\(row.subtasks.count)")
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary.opacity(0.5), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("\(row.subtasks.count) Sub-Tasks")
            }

            Spacer(minLength: 8)

            if showTime {
                Text(row.seconds.asWorkDuration)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(row.seconds > 0 ? .secondary : .tertiary)
                    .frame(width: 62, alignment: .trailing)
            }

            statusBadge(name: row.statusName, categoryKey: row.statusCategoryKey)
                .frame(width: 104, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(hovering ? AnyShapeStyle(.quaternary.opacity(0.4)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            IssueWindowManager.shared.open(issueKey: row.key)
        }
    }

    private func subtaskRow(_ subtask: ReviewStore.Row.Subtask) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            CopyableKeyLabel(key: subtask.key)
                .frame(minWidth: 92, alignment: .leading)
            Text(subtask.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if showTime {
                Text(subtask.seconds.asWorkDuration)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 62, alignment: .trailing)
            }
            Text(subtask.statusName ?? "")
                .font(.caption2)
                .foregroundStyle(subtask.isDone ? .green : .secondary)
                .lineLimit(1)
                .frame(width: 104, alignment: .trailing)
        }
        .padding(.leading, 32)
        .padding(.trailing, 12)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            IssueWindowManager.shared.open(issueKey: subtask.key)
        }
    }

    @ViewBuilder
    private func statusBadge(name: String?, categoryKey: String?) -> some View {
        if let name {
            StatusBadge(status: StatusDTO(name: name,
                                          statusCategory: StatusCategoryDTO(key: categoryKey)))
        }
    }
}
