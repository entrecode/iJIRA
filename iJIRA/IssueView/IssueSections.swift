import AppKit
import SwiftUI

// MARK: - Titel (klick-editierbar)

struct IssueTitleSection: View {
    @Bindable var model: IssueDetailModel
    let detail: IssueDetailDTO

    @State private var isEditing = false
    @State private var draft = ""
    @State private var isSaving = false
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if isEditing {
                TextField("Titel", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .focused($focused)
                    .onSubmit { Task { await save() } }
                    .onExitCommand { isEditing = false }
                if isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Sichern") { Task { await save() } }
                        .controlSize(.small)
                }
            } else {
                Text(detail.fields.summary)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                Button {
                    draft = detail.fields.summary
                    isEditing = true
                    focused = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .opacity(hovering ? 1 : 0)
                .help("Titel bearbeiten")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering = $0 }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        if await model.saveSummary(draft) {
            isEditing = false
        }
    }
}

// MARK: - Meta (Assignee, Parent, Reporter)

struct IssueMetaSection: View {
    @Bindable var model: IssueDetailModel
    let detail: IssueDetailDTO

    @State private var showAssigneePicker = false
    @State private var showParentPicker = false
    @State private var showLabelsEditor = false
    @State private var showFixVersionsEditor = false

    var body: some View {
        SectionCard(title: "Details", systemImage: "list.bullet.rectangle") {
            // Zwei Spalten: links Personen/Hierarchie, rechts Klassifizierung.
            Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    metaLabel("Assignee")
                    assigneeChip
                    metaLabel("Issue-Type")
                    issueTypeChip
                }
                GridRow {
                    metaLabel("Reporter")
                    reporterValue
                    metaLabel("Components")
                    componentsChip
                }
                GridRow {
                    metaLabel("Parent")
                    parentChip
                    metaLabel("Labels")
                    labelsChip
                }
                GridRow {
                    metaLabel("Team")
                    teamChip
                    metaLabel("Fix Version")
                    fixVersionsChip
                }
                GridRow {
                    metaLabel("Sprint")
                    sprintChip
                }
            }
        }
        .task(id: detail.key) { await model.loadEditCatalogs() }
    }

    /// Dezenter Auf-/Ab-Pfeil, der ein Feld als editierbar kennzeichnet.
    private var editChevron: some View {
        Image(systemName: "chevron.up.chevron.down")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    // MARK: Issue-Type (editierbar)

    private var issueTypeChip: some View {
        Menu {
            if model.issueTypeOptions.isEmpty {
                Button("Lädt …") {}.disabled(true)
            }
            ForEach(model.issueTypeOptions) { type in
                Button {
                    Task { _ = await model.setIssueType(id: type.id) }
                } label: {
                    if type.id == detail.fields.issuetype?.id {
                        Label(type.name, systemImage: "checkmark")
                    } else {
                        Text(type.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                IssueTypeIcon(typeName: detail.fields.issuetype?.name)
                Text(detail.fields.issuetype?.name ?? "—").font(.callout)
                Spacer(minLength: 4)
                editChevron
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Issue-Type ändern")
    }

    // MARK: Components (editierbar, Mehrfachauswahl)

    private var componentsChip: some View {
        Menu {
            if model.componentOptions.isEmpty {
                Button("Keine Komponenten im Projekt") {}.disabled(true)
            }
            ForEach(model.componentOptions) { component in
                Button {
                    Task { await toggleComponent(component) }
                } label: {
                    if currentComponentIds.contains(component.id) {
                        Label(component.name, systemImage: "checkmark")
                    } else {
                        Text(component.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                valueLabel(detail.fields.components?.map(\.name).joined(separator: ", "))
                Spacer(minLength: 4)
                editChevron
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Components ändern")
    }

    private var currentComponentIds: Set<String> {
        Set((detail.fields.components ?? []).map(\.id))
    }

    private func toggleComponent(_ component: ProjectComponentDTO) async {
        var ids = currentComponentIds
        if ids.contains(component.id) {
            ids.remove(component.id)
        } else {
            ids.insert(component.id)
        }
        _ = await model.setComponents(ids: Array(ids))
    }

    // MARK: Team (editierbar)

    private var teamChip: some View {
        Menu {
            Button("Kein Team") {
                Task { _ = await model.setTeam(nil) }
            }
            ForEach(model.teamOptions) { team in
                Button {
                    Task { _ = await model.setTeam(team) }
                } label: {
                    if team.id == model.teamId {
                        Label(team.name, systemImage: "checkmark")
                    } else {
                        Text(team.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                valueLabel(model.teamName)
                Spacer(minLength: 4)
                editChevron
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Team ändern")
    }

    // MARK: Sprint (editierbar)

    private var sprintChip: some View {
        Menu {
            Button("Kein Sprint (Backlog)") {
                Task { _ = await model.setSprint(nil) }
            }
            if model.availableSprints.isEmpty {
                Button("Keine Sprints verfügbar") {}.disabled(true)
            }
            ForEach(model.availableSprints) { sprint in
                Button {
                    Task { _ = await model.setSprint(sprint) }
                } label: {
                    if sprint.id == model.sprintId {
                        Label(sprintLabel(sprint), systemImage: "checkmark")
                    } else {
                        Text(sprintLabel(sprint))
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                valueLabel(model.sprintName)
                Spacer(minLength: 4)
                editChevron
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Sprint ändern")
    }

    private func sprintLabel(_ sprint: SprintDTO) -> String {
        sprint.state == "future" ? "\(sprint.name) (geplant)" : sprint.name
    }

    // MARK: Labels (editierbar)

    private var labelsChip: some View {
        Button {
            showLabelsEditor = true
        } label: {
            HStack(spacing: 6) {
                valueLabel(detail.fields.labels?.joined(separator: ", "))
                Spacer(minLength: 4)
                editChevron
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Labels bearbeiten")
        .popover(isPresented: $showLabelsEditor, arrowEdge: .bottom) {
            LabelsEditorView(model: model)
        }
    }

    // MARK: Fix Version (editierbar, Tippsuche wie Labels)

    private var fixVersionsChip: some View {
        Button {
            showFixVersionsEditor = true
        } label: {
            HStack(spacing: 6) {
                valueLabel(detail.fields.fixVersions?.compactMap(\.name).joined(separator: ", "))
                Spacer(minLength: 4)
                editChevron
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Fix Version bearbeiten")
        .popover(isPresented: $showFixVersionsEditor, arrowEdge: .bottom) {
            FixVersionsEditorView(model: model)
        }
    }

    private func metaLabel(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.leading)
            .frame(minWidth: 70, alignment: .leading)
    }

    /// Reiner Wert-Text mit „—"-Platzhalter (ohne Breiten-Frame — der Chip
    /// setzt Layout/Spacer selbst, damit der Pfeil einheitlich rechts sitzt).
    @ViewBuilder
    private func valueLabel(_ text: String?) -> some View {
        if let text, !text.isEmpty {
            Text(text)
                .font(.callout)
                .lineLimit(2)
        } else {
            Text("—")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var reporterValue: some View {
        if let reporter = detail.fields.reporter {
            UserLabel(user: reporter)
        } else {
            Text("—").font(.callout).foregroundStyle(.tertiary)
        }
    }

    private var assigneeChip: some View {
        Button {
            showAssigneePicker = true
        } label: {
            HStack(spacing: 6) {
                if let assignee = detail.fields.assignee {
                    UserLabel(user: assignee)
                } else {
                    Text("Nicht zugewiesen").font(.callout).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                editChevron
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showAssigneePicker, arrowEdge: .bottom) {
            PersonPickerView(
                users: model.assignableUsers.isEmpty ? model.directory.users : model.assignableUsers,
                allowUnassign: true,
                currentAccountId: detail.fields.assignee?.accountId,
                myAccountId: model.myAccountId
            ) { user in
                showAssigneePicker = false
                Task { await model.setAssignee(user) }
            }
        }
    }

    @ViewBuilder
    private var parentChip: some View {
        HStack(spacing: 6) {
            if let parent = detail.fields.parent {
                Button {
                    IssueWindowManager.shared.open(issueKey: parent.key)
                } label: {
                    HStack(spacing: 6) {
                        Text(parent.key)
                            .font(.system(.callout, design: .monospaced).weight(.medium))
                            .foregroundStyle(.tint)
                        if let summary = parent.fields?.summary {
                            Text(summary).font(.callout).lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Parent öffnen")
            } else {
                Text("Kein Parent").font(.callout).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            Button {
                showParentPicker = true
            } label: {
                editChevron
            }
            .buttonStyle(.plain)
            .help("Parent ändern")
            .popover(isPresented: $showParentPicker, arrowEdge: .bottom) {
                IssueSuggestionPicker(
                    prompt: "Epic/Parent suchen …",
                    removeLabel: detail.fields.parent != nil ? "Parent entfernen" : nil
                ) { key in
                    showParentPicker = false
                    Task { await model.setParent(key: key) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct UserLabel: View {
    let user: UserDTO

    var body: some View {
        HStack(spacing: 6) {
            AvatarView(url: user.avatar48.flatMap { URL(string: $0) }, kind: .comment, size: 20)
            Text(user.displayName ?? "?").font(.callout)
        }
    }
}

// MARK: - Labels-Editor (Popover)

/// Labels bearbeiten: aktuelle als entfernbare Chips, neue per Textfeld
/// (mit Vorschlägen aus allen Site-Labels). Änderungen werden sofort gespeichert.
struct LabelsEditorView: View {
    @Bindable var model: IssueDetailModel

    @State private var input = ""
    @FocusState private var focused: Bool

    private var current: [String] { model.detail?.fields.labels ?? [] }

    private var suggestions: [String] {
        let query = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return [] }
        return model.allLabels
            .filter { $0.lowercased().contains(query) && !current.contains($0) }
            .prefix(6)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if current.isEmpty {
                Text("Keine Labels")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                FlowLayoutLite(spacing: 6) {
                    ForEach(current, id: \.self) { label in
                        HStack(spacing: 4) {
                            Text(label).font(.callout)
                            Button {
                                Task { _ = await model.setLabels(current.filter { $0 != label }) }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary.opacity(0.4), in: Capsule())
                    }
                }
            }

            TextField("Label hinzufügen … (⏎)", text: $input)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { add(input) }

            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button {
                            add(suggestion)
                        } label: {
                            Text(suggestion)
                                .font(.callout)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(12)
        .frame(width: 300)
        .task {
            focused = true
            await model.loadAllLabels()
        }
    }

    private func add(_ raw: String) {
        // Jira-Labels dürfen keine Leerzeichen enthalten.
        let label = raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
        guard !label.isEmpty, !current.contains(label) else { return }
        input = ""
        Task { _ = await model.setLabels(current + [label]) }
    }
}

// MARK: - Fix-Version-Editor (Popover)

/// Fix Versions bearbeiten: gesetzte als entfernbare Chips, Hinzufügen per
/// Tippsuche über die Projekt-Versionen — Vorschläge absteigend sortiert
/// (höchste Version zuerst). Änderungen speichern sofort.
struct FixVersionsEditorView: View {
    @Bindable var model: IssueDetailModel

    @State private var input = ""
    @FocusState private var focused: Bool

    private var current: [FixVersionDTO] { model.detail?.fields.fixVersions ?? [] }
    private var currentIds: Set<String> { Set(current.compactMap(\.id)) }

    /// Projekt-Versionen sind im Model bereits absteigend sortiert.
    private var suggestions: [VersionDTO] {
        let query = input.trimmingCharacters(in: .whitespaces).lowercased()
        return model.projectVersions
            .filter { !currentIds.contains($0.id) }
            .filter { query.isEmpty || $0.name.lowercased().contains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if current.isEmpty {
                Text("Keine Fix Version")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                FlowLayoutLite(spacing: 6) {
                    ForEach(current.compactMap(\.id), id: \.self) { id in
                        HStack(spacing: 4) {
                            Text(current.first { $0.id == id }?.name ?? id)
                                .font(.callout)
                            Button {
                                Task {
                                    _ = await model.setFixVersions(
                                        ids: Array(currentIds.subtracting([id])))
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary.opacity(0.4), in: Capsule())
                    }
                }
            }

            TextField("Version suchen … (⏎ = erste)", text: $input)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit {
                    if let first = suggestions.first { add(first) }
                }

            if suggestions.isEmpty {
                Text(model.projectVersions.isEmpty
                     ? "Keine Versionen im Projekt"
                     : "Keine Treffer")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(suggestions.prefix(30)) { version in
                            Button {
                                add(version)
                            } label: {
                                HStack(spacing: 6) {
                                    Text(version.name).font(.callout)
                                    if version.released == true {
                                        Text("released")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 220)
                .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(12)
        .frame(width: 300)
        .task {
            focused = true
            await model.loadProjectVersions()
        }
    }

    private func add(_ version: VersionDTO) {
        input = ""
        Task {
            _ = await model.setFixVersions(ids: Array(currentIds.union([version.id])))
        }
    }
}

// MARK: - Personen-Auswahl (Popover)

/// Mac-typische Personenauswahl: Suchfeld oben, gefilterte Liste, Klick wählt.
struct PersonPickerView: View {
    let users: [UserDTO]
    let allowUnassign: Bool
    var currentAccountId: String?
    var myAccountId: String?
    let onSelect: (UserDTO?) -> Void

    @State private var query = ""
    @FocusState private var focused: Bool

    private var filtered: [UserDTO] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return users }
        return users.filter { ($0.displayName ?? "").lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Person suchen …", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .padding(8)
                .onSubmit {
                    if let first = filtered.first { onSelect(first) }
                }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if allowUnassign, query.isEmpty {
                        row(icon: "person.slash", text: "Nicht zugewiesen") { onSelect(nil) }
                        if let mine = users.first(where: { $0.accountId == myAccountId }) {
                            row(icon: "person.crop.circle.badge.checkmark", text: "Mir zuweisen") {
                                onSelect(mine)
                            }
                        }
                        Divider()
                    }
                    ForEach(filtered) { user in
                        Button {
                            onSelect(user)
                        } label: {
                            HStack(spacing: 8) {
                                AvatarView(url: user.avatar48.flatMap { URL(string: $0) },
                                           kind: .comment, size: 22)
                                Text(user.displayName ?? "?").font(.callout)
                                Spacer()
                                if user.accountId == currentAccountId {
                                    Image(systemName: "checkmark").font(.caption)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(width: 260, height: 320)
        .onAppear { focused = true }
    }

    private func row(icon: String, text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 22)
                Text(text).font(.callout)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Issue-Auswahl (Popover mit Picker-Vorschlägen)

struct IssueSuggestionPicker: View {
    let prompt: String
    var removeLabel: String? = nil
    /// Aufruf mit Key — oder nil für „entfernen".
    let onSelect: (String?) -> Void

    @State private var query = ""
    @State private var suggestions: [IssuePickerResponse.Suggestion] = []
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField(prompt, text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .padding(8)
                .onSubmit {
                    if let key = JiraKeyParser.directKey(from: query) {
                        onSelect(key)
                    } else if let first = suggestions.first {
                        onSelect(first.key)
                    }
                }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let removeLabel, query.isEmpty {
                        Button {
                            onSelect(nil)
                        } label: {
                            Label(removeLabel, systemImage: "xmark.circle")
                                .font(.callout)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                    ForEach(suggestions) { suggestion in
                        Button {
                            onSelect(suggestion.key)
                        } label: {
                            HStack(spacing: 6) {
                                Text(suggestion.key)
                                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                                    .foregroundStyle(.tint)
                                Text(suggestion.summaryText ?? "")
                                    .font(.callout)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(width: 320, height: 300)
        .onAppear { focused = true }
        .onChange(of: query) { _, newValue in
            searchTask?.cancel()
            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 2 else {
                suggestions = []
                return
            }
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled,
                      let client = IssueWindowManager.shared.appState.currentClient() else { return }
                let found = (try? await client.issuePicker(query: trimmed)) ?? []
                if !Task.isCancelled { suggestions = found }
            }
        }
    }
}

// MARK: - Beschreibung (editierbar)

struct IssueDescriptionSection: View {
    @Bindable var model: IssueDetailModel
    let detail: IssueDetailDTO

    @State private var isEditing = false
    @State private var draft = ""
    @State private var preservedNodes: [[String: Any]] = []
    @State private var preservedSummary: String?
    @State private var isSaving = false
    @State private var mentionQuery: String?
    @State private var editorController = MarkdownEditorController()

    var body: some View {
        SectionCard(title: "Beschreibung", systemImage: "text.alignleft") {
            if isEditing {
                editor
            } else {
                display
            }
        }
    }

    @ViewBuilder
    private var display: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let description = detail.fields.description {
                ADFContentView(
                    document: description,
                    resolveAttachment: { model.attachment(forMediaAlt: $0) },
                    thumbnail: { model.thumbnail(for: $0) },
                    onOpenAttachment: { model.openAttachment($0) })
            } else {
                Text("Keine Beschreibung")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            Button {
                startEditing()
            } label: {
                Label("Bearbeiten", systemImage: "pencil")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            MarkdownTextEditor(text: $draft,
                               controller: editorController,
                               onMentionQuery: { mentionQuery = $0 })
                .frame(minHeight: 140)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5),
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary, lineWidth: 1))
            MentionSuggestionsRow(directory: model.directory,
                                  query: mentionQuery,
                                  controller: editorController)
            if let preservedSummary {
                Label("Bleibt erhalten, rückt ans Ende: \(preservedSummary)",
                      systemImage: "paperclip")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Formatierung: **fett** *kursiv* `code` ``` # Liste - @Name KEY-123")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
                    .lineLimit(1)
                Spacer()
                Button("Abbrechen") { isEditing = false }
                    .controlSize(.small)
                if isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Sichern") { Task { await save() } }
                        .controlSize(.small)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
    }

    private func startEditing() {
        let conversion = model.descriptionConversion()
        draft = conversion.markdown
        preservedNodes = conversion.preservedNodes
        preservedSummary = conversion.preservedSummary
        isEditing = true
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        if await model.saveDescription(markdown: draft, preservedNodes: preservedNodes) {
            isEditing = false
        }
    }
}

// MARK: - Mention-Vorschläge

/// Vorschlagszeile unter einem Editor, sobald hinter „@" getippt wird.
/// Klick fügt das Mention-Token an der Cursor-Position ein.
struct MentionSuggestionsRow: View {
    let directory: UserDirectory
    let query: String?
    let controller: MarkdownEditorController

    var body: some View {
        if let query {
            let matches = directory.matching(query).prefix(5)
            if !matches.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(matches)) { user in
                        Button {
                            controller.insertMention(user)
                        } label: {
                            HStack(spacing: 5) {
                                AvatarView(url: user.avatar48.flatMap { URL(string: $0) },
                                           kind: .comment, size: 18)
                                Text(user.displayName ?? "?")
                                    .font(.caption)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary.opacity(0.4), in: Capsule())
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// MARK: - Anhänge

struct IssueAttachmentsSection: View {
    @Bindable var model: IssueDetailModel

    var body: some View {
        SectionCard(title: "Anhänge (\(model.attachments.count))", systemImage: "paperclip") {
            FlowLayoutLite(spacing: 8) {
                ForEach(model.attachments) { attachment in
                    AttachmentTile(attachment: attachment,
                                   image: model.thumbnail(for: attachment),
                                   onOpen: { model.openAttachment(attachment) })
                        .overlay(alignment: .topTrailing) {
                            if model.openingAttachments.contains(attachment.id) {
                                ProgressView().controlSize(.small).padding(4)
                            }
                        }
                }
            }
        }
    }
}

// MARK: - Verlinkte Vorgänge (editierbar)

struct IssueLinksSection: View {
    @Bindable var model: IssueDetailModel
    let detail: IssueDetailDTO

    var body: some View {
        SectionCard(title: "Verlinkte Vorgänge", systemImage: "link") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(detail.fields.issuelinks ?? []) { link in
                    if let other = link.other {
                        LinkRow(model: model, link: link, other: other)
                    }
                }
                AddLinkButton(model: model)
            }
        }
    }
}

private struct LinkRow: View {
    @Bindable var model: IssueDetailModel
    let link: IssueLinkDTO
    let other: (issue: LinkedIssueDTO, label: String)

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(other.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 90, alignment: .leading)
            Button {
                IssueWindowManager.shared.open(issueKey: other.issue.key)
            } label: {
                HStack(spacing: 6) {
                    Text(other.issue.key)
                        .font(.system(.callout, design: .monospaced).weight(.medium))
                        .foregroundStyle(.tint)
                    Text(other.issue.fields?.summary ?? "")
                        .font(.callout)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            if let status = other.issue.fields?.status {
                StatusBadge(status: status)
            }
            Button {
                Task { await model.removeLink(id: link.id) }
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .opacity(hovering ? 1 : 0)
            .help("Verknüpfung entfernen")
        }
        .onHover { hovering = $0 }
    }
}

/// „Verknüpfung hinzufügen": Link-Typ (mit Richtung) wählen + Issue suchen.
private struct AddLinkButton: View {
    @Bindable var model: IssueDetailModel

    @State private var showPopover = false
    @State private var selectedOption: LinkOption?

    struct LinkOption: Identifiable, Hashable {
        let typeName: String
        let label: String
        let direction: IssueDetailModel.LinkDirection
        var id: String { typeName + label }
        static func == (lhs: LinkOption, rhs: LinkOption) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    private var options: [LinkOption] {
        model.linkTypes.flatMap { type -> [LinkOption] in
            guard let name = type.name else { return [] }
            var result: [LinkOption] = []
            // Label „blocks" = dieses Issue ist die outward-Seite des Links.
            if let outward = type.outward {
                result.append(LinkOption(typeName: name, label: outward, direction: .outward))
            }
            if let inward = type.inward, inward != type.outward {
                result.append(LinkOption(typeName: name, label: inward, direction: .inward))
            }
            return result
        }
    }

    var body: some View {
        Button {
            showPopover = true
            Task { await model.loadLinkTypes() }
        } label: {
            Label("Verknüpfung hinzufügen", systemImage: "plus")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            VStack(spacing: 8) {
                Picker("Beziehung", selection: $selectedOption) {
                    Text("Beziehung wählen …").tag(LinkOption?.none)
                    ForEach(options) { option in
                        Text("\(model.issueKey) \(option.label) …").tag(Optional(option))
                    }
                }
                .labelsHidden()
                .padding(.horizontal, 8)
                .padding(.top, 8)

                IssueSuggestionPicker(prompt: "Issue suchen …") { key in
                    guard let key, let option = selectedOption else { return }
                    showPopover = false
                    Task {
                        await model.addLink(typeName: option.typeName,
                                            direction: option.direction,
                                            otherKey: key)
                    }
                }
                .disabled(selectedOption == nil)
                .opacity(selectedOption == nil ? 0.5 : 1)
            }
            .frame(width: 336)
            .padding(.bottom, 4)
        }
    }
}

// MARK: - Kommentare

struct IssueCommentsSection: View {
    @Bindable var model: IssueDetailModel

    @State private var draft = ""
    @State private var isSending = false
    @State private var mentionQuery: String?
    @State private var editorController = MarkdownEditorController()

    var body: some View {
        SectionCard(title: "Kommentare (\(model.comments.count))", systemImage: "text.bubble") {
            VStack(alignment: .leading, spacing: 14) {
                if model.comments.isEmpty {
                    Text("Noch keine Kommentare")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                ForEach(model.comments, id: \.id) { comment in
                    CommentRow(model: model, comment: comment)
                }
                composer
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            ZStack(alignment: .topLeading) {
                MarkdownTextEditor(text: $draft,
                                   controller: editorController,
                                   onMentionQuery: { mentionQuery = $0 })
                    .frame(height: 76)
                if draft.isEmpty {
                    Text("Kommentieren… (`code`, **fett**, *kursiv*, @Name, ONE-123)")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            MentionSuggestionsRow(directory: model.directory,
                                  query: mentionQuery,
                                  controller: editorController)
            HStack {
                Spacer()
                if isSending { ProgressView().controlSize(.small) }
                Button("Senden") {
                    Task { await send() }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
            }
        }
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSending = true
        defer { isSending = false }
        if await model.addComment(markdown: text) {
            draft = ""
        }
    }
}

private struct CommentRow: View {
    @Bindable var model: IssueDetailModel
    let comment: CommentDTO

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            AvatarView(url: comment.author?.avatar48.flatMap { URL(string: $0) },
                       kind: .comment, size: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(comment.author?.displayName ?? "jemand")
                        .font(.caption.weight(.semibold))
                    if let created = JiraDate.parse(comment.created) {
                        RelativeTimeText(date: created)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                if let body = comment.body {
                    ADFContentView(
                        document: body,
                        resolveAttachment: { model.attachment(forMediaAlt: $0) },
                        thumbnail: { model.thumbnail(for: $0) },
                        onOpenAttachment: { model.openAttachment($0) })
                }
            }
        }
    }
}
