import AppKit
import SwiftUI

/// Fensterinhalt der Issue-Detail-Ansicht: konzentriert aufs Wesentliche —
/// Titel, Key, Parent, Beschreibung, Assignee, verlinkte Vorgänge, Kommentare.
struct IssueDetailView: View {
    @Bindable var model: IssueDetailModel

    @State private var copiedKey = false

    var body: some View {
        ZStack {
            WindowBackdrop().ignoresSafeArea()
            VStack(spacing: 0) {
                IssueWindowHeader(model: model, copiedKey: $copiedKey)
                Divider().opacity(0.4)
                content
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .task { await model.load() }
        // Browse-Links (Ticket-Karten, Kommentar-Links) öffnen die Detailview
        // statt des Browsers; alles andere geht ins System.
        .environment(\.openURL, OpenURLAction { url in
            if url.absoluteString.contains("/browse/"),
               let key = JiraKeyParser.key(from: url.lastPathComponent) {
                IssueWindowManager.shared.open(issueKey: key)
                return .handled
            }
            return .systemAction
        })
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.loadError {
            ContentUnavailableView {
                Label("Konnte nicht laden", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Erneut versuchen") { Task { await model.load() } }
            }
        } else if model.detail == nil {
            ProgressView("Lade \(model.issueKey) …")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let detail = model.detail {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    IssueTitleSection(model: model, detail: detail)
                    IssueMetaSection(model: model, detail: detail)
                    IssueDescriptionSection(model: model, detail: detail)
                    if !model.attachments.isEmpty {
                        IssueAttachmentsSection(model: model)
                    }
                    if !(detail.fields.issuelinks ?? []).isEmpty {
                        IssueLinksSection(model: model, detail: detail)
                    }
                    IssueCommentsSection(model: model)
                }
                .padding(20)
            }
            .overlay(alignment: .bottom) {
                if let actionError = model.actionError {
                    ErrorToast(message: actionError) { model.actionError = nil }
                }
            }
        }
    }
}

// MARK: - Header (Key, Status, Suche, Web-Link)

private struct IssueWindowHeader: View {
    @Bindable var model: IssueDetailModel
    @Binding var copiedKey: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Platz für die Ampel-Buttons (transparente Titlebar).
            Spacer().frame(width: 66)

            keyChip

            if let status = model.detail?.fields.status {
                StatusBadge(status: status)
            }

            Spacer()

            IssueSearchField()
                .frame(width: 230)

            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Aktualisieren")

            if let url = model.webURL {
                Link(destination: url) {
                    Image(systemName: "safari")
                }
                .help("Im Web öffnen")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// Issue-Key als kopierbarer Chip.
    private var keyChip: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(model.issueKey, forType: .string)
            copiedKey = true
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                copiedKey = false
            }
        } label: {
            HStack(spacing: 5) {
                Text(model.issueKey)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                Image(systemName: copiedKey ? "checkmark" : "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(copiedKey ? .green : .secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .glassChip()
        .help("Key kopieren")
    }
}

/// Farbige Status-Kapsel (Farbe aus der Jira-Statuskategorie).
struct StatusBadge: View {
    let status: StatusDTO

    var body: some View {
        Text(status.name)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
    }

    private var color: Color {
        switch status.statusCategory?.key {
        case "done": return .green
        case "indeterminate": return .blue
        default: return .secondary
        }
    }
}

// MARK: - Suchfeld mit Vorschlägen

/// Key/Link einfügen und Enter → Fenster öffnet direkt. Freitext zeigt
/// Issue-Vorschläge (Jira-Picker: Verlauf + Volltext).
struct IssueSearchField: View {
    @State private var query = ""
    @State private var suggestions: [IssuePickerResponse.Suggestion] = []
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Key, Link oder Suche …", text: $query)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($focused)
                .onSubmit(openBest)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .glassChip()
        .onChange(of: query) { _, newValue in
            scheduleSearch(newValue)
        }
        .overlay(alignment: .topLeading) {
            if focused && !suggestions.isEmpty {
                suggestionList
                    .offset(y: 30)
            }
        }
        .onExitCommand {
            query = ""
            suggestions = []
            focused = false
        }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(suggestions.prefix(6)) { suggestion in
                Button {
                    open(key: suggestion.key)
                } label: {
                    HStack(spacing: 6) {
                        Text(suggestion.key)
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                            .foregroundStyle(.tint)
                        Text(suggestion.summaryText ?? "")
                            .font(.caption)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if suggestion.id != suggestions.prefix(6).last?.id {
                    Divider()
                }
            }
        }
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary, lineWidth: 1))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
    }

    private func scheduleSearch(_ text: String) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Direkte Keys/Links brauchen keine Vorschläge.
        guard trimmed.count >= 2, JiraKeyParser.directKey(from: trimmed) == nil else {
            suggestions = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled,
                  let client = IssueWindowManager.shared.appState.currentClient() else { return }
            let found = (try? await client.issuePicker(query: trimmed)) ?? []
            if !Task.isCancelled {
                suggestions = found
            }
        }
    }

    private func openBest() {
        if let key = JiraKeyParser.directKey(from: query) ?? JiraKeyParser.key(from: query) {
            open(key: key)
        } else if let first = suggestions.first {
            open(key: first.key)
        }
    }

    private func open(key: String) {
        query = ""
        suggestions = []
        focused = false
        IssueWindowManager.shared.open(issueKey: key)
    }
}

// MARK: - Fehler-Toast

struct ErrorToast: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message).font(.callout).lineLimit(2)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.quaternary, lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        .padding(.bottom, 14)
    }
}

// MARK: - Design-Helfer

/// Frosted-Backdrop hinter dem Fensterinhalt.
struct WindowBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

extension View {
    /// Liquid-Glass-Kapsel auf macOS 26+, Material-Fallback davor.
    @ViewBuilder
    func glassChip() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self.background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(.quaternary, lineWidth: 1))
        }
    }
}

/// Abgesetzte Inhalts-Karte mit Sektionstitel.
struct SectionCard<Content: View>: View {
    let title: String
    var systemImage: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .kerning(0.4)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary.opacity(0.6), lineWidth: 1))
    }
}
