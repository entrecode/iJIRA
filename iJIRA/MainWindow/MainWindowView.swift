import SwiftUI

/// Inhalt des Hauptfensters: Header mit Zurück-Button, Board/Issue/Review-
/// Umschalter und dem immer sichtbaren Suchfeld, darunter der aktive Tab.
struct MainWindowView: View {
    @Bindable var model: MainWindowModel
    @Bindable var boardStore: BoardStore
    @Bindable var reviewStore: ReviewStore

    /// Board und Review werden beim ersten Besuch aufgebaut und bleiben dann
    /// bestehen (nur ausgeblendet) — so behalten sie Scrollposition und
    /// Klappzustände, egal ob man per Zurück, Umschalter oder ⌘1–3 wiederkommt.
    @State private var visitedTabs: Set<MainWindowModel.Tab> = []

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
            // Ganz links: Der Header liegt unterhalb der Titelleiste, die
            // Ampel-Buttons brauchen hier keinen Platz.
            backButton

            Picker("Ansicht", selection: tabSelection) {
                Text("Board").tag(MainWindowModel.Tab.board)
                Text("Issue").tag(MainWindowModel.Tab.issue)
                Text("Review & Plan").tag(MainWindowModel.Tab.review)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)

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
        // Ganzer Header zieht das Fenster (nicht nur die schmale Titlebar);
        // das Bar-Material liegt als eigene Schicht dahinter (behält sein
        // Safe-Area-Verhalten — im ZStack wurde es weiß).
        .background(WindowDragArea())
        .background(.bar)
    }

    /// Umschalter → Verlauf (jeder Tab-Wechsel ist ein Schritt zurück).
    private var tabSelection: Binding<MainWindowModel.Tab> {
        Binding(get: { model.tab }, set: { model.navigate(toTab: $0) })
    }

    // MARK: - Zurück

    /// Sieht aus wie die Tab-Segmente, mit etwas Abstand davor abgesetzt.
    private var backButton: some View {
        BackSegmentButton(
            entries: model.backStack.reversed().map { model.title(for: $0) },
            help: backHelp
        ) { steps, inNewWindow in
            MainWindowController.shared.goBack(steps: steps, inNewWindow: inNewWindow)
        }
        .fixedSize()
        .padding(.trailing, 8)
    }

    private var backHelp: String {
        guard let target = model.backTarget() else { return "Zurück (⌘[)" }
        return "Zurück zu \(model.title(for: target)) (⌘[) — gedrückt halten für den Verlauf, ⌘-Klick öffnet ein Issue im neuen Fenster"
    }

    // MARK: - Inhalt

    private var content: some View {
        ZStack {
            if model.tab == .board || visitedTabs.contains(.board) {
                // Greedy füllen, sonst zentriert der äußere VStack den Header mit.
                BoardView(store: boardStore)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .tabLayer(active: model.tab == .board)
            }
            if model.tab == .review || visitedTabs.contains(.review) {
                ReviewView(store: reviewStore)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .tabLayer(active: model.tab == .review)
            }
            // Bewusst nicht am Leben gehalten: ein versteckter Editor würde
            // sonst Tastatureingaben schlucken.
            if model.tab == .issue {
                issueContent
            }
        }
        .onChange(of: model.tab, initial: true) { _, tab in
            visitedTabs.insert(tab)
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

private extension View {
    /// Ebene im Tab-Stapel: unsichtbar und nicht bedienbar, solange inaktiv —
    /// bleibt aber im View-Baum (Scrollposition, Klappzustände).
    func tabLayer(active: Bool) -> some View {
        opacity(active ? 1 : 0)
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
    }
}
