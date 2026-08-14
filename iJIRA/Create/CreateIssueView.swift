import SwiftUI

/// „Neues Issue"-Dialog (Sheet im Hauptfenster, ⌘N). Projekt, Typ, Team und
/// Komponenten als Dropdowns — vorbelegt vom zuletzt angelegten bzw. zuletzt
/// angesehenen Ticket.
struct CreateIssueView: View {
    let service: CreateIssueService
    /// Wird mit dem neuen Key aufgerufen (Detailview öffnen).
    let onCreated: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var projectKey: String?
    @State private var issueTypes: [CreateMetaIssueType] = []
    @State private var issueTypeId: String?
    @State private var components: [ProjectComponentDTO] = []
    @State private var selectedComponentIds: Set<String> = []
    @State private var teamId: String?
    @State private var summary = ""
    @State private var descriptionText = ""
    @State private var mentionQuery: String?
    @State private var editorController = MarkdownEditorController()
    @State private var isCreating = false
    @State private var errorMessage: String?
    @FocusState private var summaryFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Neues Issue")
                .font(.title3.weight(.semibold))

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    gridLabel("Projekt")
                    Picker("Projekt", selection: $projectKey) {
                        ForEach(service.projects) { project in
                            Text("\(project.name) (\(project.key))").tag(Optional(project.key))
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    gridLabel("Typ")
                    Picker("Typ", selection: $issueTypeId) {
                        ForEach(issueTypes) { type in
                            Text(type.name).tag(Optional(type.id))
                        }
                    }
                    .labelsHidden()
                    .disabled(issueTypes.isEmpty)
                }
                GridRow {
                    gridLabel("Team")
                    teamPicker
                }
                GridRow {
                    gridLabel("Components")
                    componentsPicker
                }
            }

            TextField("Titel", text: $summary)
                .textFieldStyle(.roundedBorder)
                .font(.body)
                .focused($summaryFocused)

            ZStack(alignment: .topLeading) {
                MarkdownTextEditor(text: $descriptionText,
                                   controller: editorController,
                                   onMentionQuery: { mentionQuery = $0 })
                    .frame(height: 120)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.5),
                                in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary, lineWidth: 1))
                if descriptionText.isEmpty {
                    Text("Beschreibung… (`code`, **fett**, @Name, ONE-123)")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            MentionSuggestionsRow(directory: IssueWindowManager.shared.userDirectory,
                                  query: mentionQuery,
                                  controller: editorController)

            HStack(spacing: 10) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                Spacer()
                Button("Abbrechen") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if isCreating {
                    ProgressView().controlSize(.small)
                }
                Button("Erstellen") {
                    Task { await create() }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!canCreate)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task { await initialLoad() }
        .onChange(of: projectKey) { oldValue, newValue in
            // Beim ersten Setzen (initialLoad) nicht doppelt laden.
            guard oldValue != nil, oldValue != newValue else { return }
            Task { await projectChanged(keepSelections: false) }
        }
    }

    private var canCreate: Bool {
        !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && projectKey != nil && issueTypeId != nil && !isCreating
    }

    private func gridLabel(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(minWidth: 84, alignment: .leading)
    }

    // MARK: - Team & Components

    @ViewBuilder
    private var teamPicker: some View {
        Picker("Team", selection: $teamId) {
            Text("Kein Team").tag(String?.none)
            ForEach(teamOptions) { team in
                Text(team.name).tag(Optional(team.id))
            }
        }
        .labelsHidden()
        .disabled(service.teamFieldId == nil)
    }

    /// Team-Liste; enthält den Default auch dann, wenn er (noch) nicht in den
    /// geladenen Vorschlägen steckt.
    private var teamOptions: [CreateIssueService.TeamOption] {
        var options = service.teams
        if let teamId, !options.contains(where: { $0.id == teamId }) {
            let name = service.startDefaults.teamName ?? "Aktuelles Team"
            options.insert(CreateIssueService.TeamOption(id: teamId, name: name), at: 0)
        }
        return options
    }

    private var componentsPicker: some View {
        Menu {
            if components.isEmpty {
                Button("Keine Komponenten im Projekt") {}.disabled(true)
            }
            ForEach(components) { component in
                // Toggle statt Button mit eigenem Checkmark: nur so lässt sich
                // die Auswahl im macOS-Menü zuverlässig auch wieder abwählen.
                Toggle(component.name, isOn: componentSelectionBinding(component.id))
            }
        } label: {
            Text(selectedComponentsLabel)
                .foregroundStyle(selectedComponentIds.isEmpty ? .secondary : .primary)
        }
        .menuStyle(.borderlessButton)
        .disabled(components.isEmpty)
    }

    private func componentSelectionBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { selectedComponentIds.contains(id) },
            set: { isOn in
                if isOn {
                    selectedComponentIds.insert(id)
                } else {
                    selectedComponentIds.remove(id)
                }
            })
    }

    private var selectedComponentsLabel: String {
        let names = components.filter { selectedComponentIds.contains($0.id) }.map(\.name)
        if names.isEmpty {
            return components.isEmpty ? "Keine im Projekt" : "Keine ausgewählt"
        }
        return names.joined(separator: ", ")
    }

    // MARK: - Laden & Anlegen

    private func initialLoad() async {
        await service.preload()
        let defaults = service.startDefaults
        projectKey = defaults.projectKey ?? service.projects.first?.key
        teamId = defaults.teamId
        await projectChanged(keepSelections: true)
        summaryFocused = true
    }

    /// Typen + Komponenten fürs gewählte Projekt laden. `keepSelections`
    /// übernimmt die Vorbelegung (nur beim Öffnen — Projektwechsel setzt zurück).
    private func projectChanged(keepSelections: Bool) async {
        guard let projectKey else { return }
        issueTypes = await service.issueTypes(projectKey: projectKey)
        components = await service.components(projectKey: projectKey)

        let defaults = service.startDefaults
        if keepSelections, defaults.projectKey == projectKey {
            issueTypeId = defaults.issueTypeId.flatMap { id in
                issueTypes.contains { $0.id == id } ? id : nil
            }
            selectedComponentIds = Set(defaults.componentIds.filter { id in
                components.contains { $0.id == id }
            })
        } else if !keepSelections {
            selectedComponentIds = []
            issueTypeId = nil
        }
        if issueTypeId == nil {
            // Sinnvoller Standard: "Task"/"Aufgabe", sonst erster Typ.
            issueTypeId = issueTypes.first {
                ["task", "aufgabe"].contains($0.name.lowercased())
            }?.id ?? issueTypes.first?.id
        }
    }

    private func create() async {
        guard let projectKey, let issueTypeId else { return }
        isCreating = true
        defer { isCreating = false }
        errorMessage = nil
        do {
            let key = try await service.create(
                projectKey: projectKey,
                issueTypeId: issueTypeId,
                summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
                descriptionMarkdown: descriptionText,
                teamId: teamId,
                componentIds: Array(selectedComponentIds))
            dismiss()
            onCreated(key)
        } catch {
            errorMessage = (error as? JiraError)?.userMessage ?? error.localizedDescription
        }
    }
}
