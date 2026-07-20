import SwiftUI

/// Popover-Inhalt: Inbox (Konversationen) ⇄ Chat-Verlauf, oder Account-
/// Einstellungen. Navigation wird bewusst manuell über `selectedIssue`
/// gesteuert (vorhersehbarer als NavigationStack im Popover).
struct RootView: View {
    @Bindable var appState: AppState
    let store: NotificationStore
    let syncEngine: SyncEngine

    @State private var selectedIssue: String?

    private var showingConversations: Bool { appState.isConnected }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 380, height: 520)
        // Popover ist .applicationDefined — Esc schließt es hier explizit.
        .onExitCommand {
            MenuBarController.shared?.closePopover()
        }
    }

    @ViewBuilder
    private var content: some View {
        if !showingConversations {
            VStack(alignment: .leading, spacing: 16) {
                statusBanner
                Button("Einstellungen öffnen …") {
                    SettingsWindowController.shared.show()
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if let issue = selectedIssue {
            ConversationView(issueKey: issue, store: store, appState: appState)
        } else {
            VStack(spacing: 0) {
                inboxToolbar
                Divider()
                ConversationsListView(onSelect: { selectedIssue = $0 })
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            if showingConversations, let issue = selectedIssue {
                Button { selectedIssue = nil } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                Text(issue).font(.headline)
            } else {
                Image(systemName: "bell.fill").foregroundStyle(.tint)
                Text("iJIRA").font(.headline)
            }
            Spacer()
            if syncEngine.isSyncing {
                ProgressView().controlSize(.small)
            }
            if selectedIssue == nil {
                Button {
                    MainWindowController.shared.show()
                } label: {
                    Image(systemName: "macwindow")
                }
                .buttonStyle(.borderless)
                .help("Hauptfenster öffnen")

                Button {
                    SettingsWindowController.shared.show()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Einstellungen")
            }
            Circle().fill(statusColor).frame(width: 9, height: 9)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Inbox toolbar

    private var inboxToolbar: some View {
        HStack {
            Button {
                Task { await syncEngine.syncNow() }
            } label: {
                Label("Aktualisieren", systemImage: "arrow.clockwise")
            }
            .disabled(syncEngine.isSyncing)

            Spacer()

            if let error = syncEngine.lastError {
                Text(error).font(.caption2).foregroundStyle(.orange).lineLimit(1)
                Spacer()
            }

            Button("Alle gelesen") { store.markAllRead() }
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Status

    private var statusBanner: some View {
        Group {
            switch appState.connection {
            case .disconnected:
                label("Nicht verbunden", systemImage: "circle.dashed", color: .secondary)
            case .connecting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Verbinde …").foregroundStyle(.secondary)
                }
            case .connected(let name, let mail):
                VStack(alignment: .leading, spacing: 4) {
                    label("Verbunden als \(name)", systemImage: "checkmark.circle.fill", color: .green)
                    Text(mail).font(.caption).foregroundStyle(.secondary)
                }
            case .failed(let message):
                label(message, systemImage: "exclamationmark.triangle.fill", color: .orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func label(_ text: String, systemImage: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(color)
            Text(text)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            // Gesundheits-Indikator: bleibt der Zeitstempel stehen, stimmt
            // etwas mit dem Sync nicht.
            if let synced = syncEngine.lastSyncedAt {
                HStack(spacing: 3) {
                    Text("Aktualisiert")
                    RelativeTimeText(date: synced)
                }
                .font(.caption2)
                .foregroundStyle(syncEngine.lastError == nil ? Color.secondary : Color.orange)
                .help(syncEngine.lastError ?? "Sync läuft normal")
            }
            Spacer()
            Button("Beenden") { NSApp.terminate(nil) }
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

    private var statusColor: Color {
        switch appState.connection {
        case .connected: return .green
        case .connecting: return .yellow
        case .failed: return .orange
        case .disconnected: return .secondary
        }
    }

}
