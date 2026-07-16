import ServiceManagement
import SwiftUI

/// Popover-Inhalt: Inbox (Konversationen) ⇄ Chat-Verlauf, oder Account-
/// Einstellungen. Navigation wird bewusst manuell über `selectedIssue`
/// gesteuert (vorhersehbarer als NavigationStack im Popover).
struct RootView: View {
    @Bindable var appState: AppState
    let store: NotificationStore
    let syncEngine: SyncEngine

    @State private var showSettings = false
    @State private var selectedIssue: String?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    private let tokenURL = URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!

    private var showingConversations: Bool { appState.isConnected && !showSettings }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 380, height: 520)
    }

    @ViewBuilder
    private var content: some View {
        if !showingConversations {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statusBanner
                    settingsForm
                }
                .padding(16)
            }
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
            if appState.isConnected && selectedIssue == nil {
                Button {
                    showSettings.toggle()
                } label: {
                    Image(systemName: showSettings ? "list.bullet" : "gearshape")
                }
                .buttonStyle(.borderless)
                .help(showSettings ? "Zur Inbox" : "Einstellungen")
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

    // MARK: - Settings form

    private var settingsForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Account")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            field(title: "Jira Site-URL") {
                TextField("https://dein-team.atlassian.net", text: $appState.siteURLString)
                    .textFieldStyle(.roundedBorder)
            }

            field(title: "E-Mail") {
                TextField("name@firma.de", text: $appState.email)
                    .textFieldStyle(.roundedBorder)
            }

            field(title: "API-Token") {
                SecureField("API-Token", text: $appState.apiToken)
                    .textFieldStyle(.roundedBorder)
                Link("API-Token erstellen …", destination: tokenURL).font(.caption)
            }

            HStack {
                Button(action: connect) {
                    Text(appState.isConnected ? "Erneut prüfen" : "Verbinden")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(appState.isConnecting)

                if appState.isConnected {
                    Button("Trennen", role: .destructive, action: appState.disconnect)
                }
            }
            .padding(.top, 4)

            Divider().padding(.vertical, 4)

            Text("Allgemein")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Toggle("Bei Anmeldung starten", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enable in
                    setLaunchAtLogin(enable)
                }
            if let error = launchAtLoginError {
                Text(error).font(.caption2).foregroundStyle(.orange)
            }
        }
    }

    /// Registriert die App als Login-Item (bzw. entfernt sie wieder). Läuft
    /// die App nicht aus /Applications (z. B. Debug-Build), kann das System
    /// die Registrierung ablehnen — dann Toggle zurücksetzen und Fehler zeigen.
    private func setLaunchAtLogin(_ enable: Bool) {
        let service = SMAppService.mainApp
        guard enable != (service.status == .enabled) else { return }
        do {
            if enable {
                try service.register()
            } else {
                try service.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Login-Item konnte nicht geändert werden: \(error.localizedDescription)"
            launchAtLogin = service.status == .enabled
        }
    }

    private func field<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
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

    private func connect() {
        Task { await appState.connect() }
    }
}
