import SwiftUI

/// Inhalt des Hauptfensters: Header mit Board/Issue-Umschalter und dem
/// immer sichtbaren Suchfeld, darunter der aktive Tab.
struct MainWindowView: View {
    @Bindable var model: MainWindowModel
    @Bindable var boardStore: BoardStore

    var body: some View {
        ZStack {
            WindowBackdrop().ignoresSafeArea()
            VStack(spacing: 0) {
                // zIndex hebt das Such-Vorschläge-Overlay über den Tab-Inhalt
                // (spätere VStack-Geschwister lägen sonst darüber).
                header
                    .zIndex(10)
                Divider().opacity(0.4)
                content
            }
        }
        .frame(minWidth: 900, minHeight: 640)
        .sheet(isPresented: $model.showCreateSheet) {
            CreateIssueView(service: CreateIssueService.shared) { key in
                model.openIssue(key)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            // Platz für die Ampel-Buttons (transparente Titlebar).
            Spacer().frame(width: 66)

            Picker("Ansicht", selection: $model.tab) {
                Text("Board").tag(MainWindowModel.Tab.board)
                Text("Issue").tag(MainWindowModel.Tab.issue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)

            Spacer()

            IssueSearchField()
                .frame(width: 240)

            Button {
                model.showCreateSheet = true
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .help("Neues Issue (⌘N)")

            Button {
                MainWindowController.shared.refreshCurrentTab()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Aktualisieren (⌘R)")

            Button {
                SettingsWindowController.shared.show()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Einstellungen (⌘,)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Inhalt

    @ViewBuilder
    private var content: some View {
        switch model.tab {
        case .board:
            // Greedy füllen, sonst zentriert der äußere VStack den Header mit.
            BoardView(store: boardStore)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .issue:
            issueContent
        }
    }

    @ViewBuilder
    private var issueContent: some View {
        if let key = model.currentIssueKey {
            IssueDetailContent(model: model.issueModel(for: key))
                .id(key)
        } else {
            emptyIssueState
        }
    }

    private var emptyIssueState: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 42))
                .foregroundStyle(.tertiary)
            Text("Kein Issue geöffnet")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Jira-Key oder Link einfügen und mit ⏎ öffnen.")
                .font(.callout)
                .foregroundStyle(.tertiary)
            IssueSearchField()
                .frame(width: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
