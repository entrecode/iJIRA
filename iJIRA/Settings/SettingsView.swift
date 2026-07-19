import ServiceManagement
import SwiftUI

/// Inhalt des Einstellungs-Fensters.
struct SettingsView: View {
    @Bindable var appState: AppState

    var body: some View {
        TabView {
            ConnectionSettingsView(appState: appState)
                .tabItem { Label("Verbindung", systemImage: "link") }
            HarvestSettingsView(harvest: HarvestState.shared)
                .tabItem { Label("Harvest", systemImage: "clock") }
            GeneralSettingsView()
                .tabItem { Label("Allgemein", systemImage: "gearshape") }
        }
        .frame(width: 460)
        .padding(.bottom, 8)
    }
}

// MARK: - Verbindung (Jira)

struct ConnectionSettingsView: View {
    @Bindable var appState: AppState

    private let tokenURL = URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusBanner

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
                Button {
                    Task { await appState.connect() }
                } label: {
                    Text(appState.isConnected ? "Erneut prüfen" : "Verbinden")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(appState.isConnecting)

                if appState.isConnected {
                    Button("Trennen", role: .destructive, action: appState.disconnect)
                }
            }
            .padding(.top, 4)
        }
        .padding(20)
    }

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

    private func field<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }
}

// MARK: - Harvest

struct HarvestSettingsView: View {
    @Bindable var harvest: HarvestState

    private let developersURL = URL(string: "https://id.getharvest.com/developers")!

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            status

            field(title: "Personal Access Token") {
                SecureField("Token", text: $harvest.accessToken)
                    .textFieldStyle(.roundedBorder)
            }
            field(title: "Account-ID") {
                TextField("z. B. 1234567", text: $harvest.accountId)
                    .textFieldStyle(.roundedBorder)
                Link("Token + Account-ID erstellen …", destination: developersURL)
                    .font(.caption)
            }

            HStack {
                Button(harvest.verifiedUserName == nil ? "Verbinden" : "Erneut prüfen") {
                    Task { await harvest.verify() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(harvest.isVerifying)
                if harvest.isVerifying {
                    ProgressView().controlSize(.small)
                }
                if harvest.verifiedUserName != nil {
                    Button("Trennen", role: .destructive) {
                        harvest.disconnect()
                    }
                }
            }

            if !harvest.assignments.isEmpty {
                Divider().padding(.vertical, 4)

                Picker("Projekt", selection: $harvest.projectId) {
                    Text("Bitte wählen …").tag(Int?.none)
                    ForEach(harvest.assignments) { assignment in
                        Text(projectLabel(assignment)).tag(Optional(assignment.project.id))
                    }
                }

                Picker("Aufgabe (Billable Type)", selection: $harvest.taskId) {
                    Text("Bitte wählen …").tag(Int?.none)
                    ForEach(harvest.availableTasks) { taskAssignment in
                        Text(taskLabel(taskAssignment)).tag(Optional(taskAssignment.task.id))
                    }
                }
                .disabled(harvest.projectId == nil)

                Text("Gilt fix für alle Issues. Der Zeit-Button erscheint in der Issue-Ansicht, sobald beides gewählt ist.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .task { await harvest.loadAssignmentsIfNeeded() }
    }

    @ViewBuilder
    private var status: some View {
        if let name = harvest.verifiedUserName {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Verbunden als \(name)")
            }
        } else if let error = harvest.verifyError {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error)
            }
        } else {
            HStack(spacing: 8) {
                Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                Text("Nicht verbunden").foregroundStyle(.secondary)
            }
        }
    }

    private func projectLabel(_ assignment: HarvestProjectAssignment) -> String {
        if let client = assignment.client?.name, !client.isEmpty {
            return "\(client) — \(assignment.project.name)"
        }
        return assignment.project.name
    }

    private func taskLabel(_ taskAssignment: HarvestTaskAssignment) -> String {
        taskAssignment.billable == true
            ? "\(taskAssignment.task.name) (billable)"
            : taskAssignment.task.name
    }

    private func field<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }
}

// MARK: - Allgemein

struct GeneralSettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?
    @AppStorage("showWindowOnLaunch") private var showWindowOnLaunch = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Bei Anmeldung starten", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enable in
                    setLaunchAtLogin(enable)
                }
            if let error = launchAtLoginError {
                Text(error).font(.caption2).foregroundStyle(.orange)
            }

            Toggle("Beim Start das Board-Fenster öffnen", isOn: $showWindowOnLaunch)
            Text("Aus = die App startet still in der Menüleiste (z. B. für den Autostart). Das Fenster öffnet sich jederzeit über das Dock, die Menüleiste oder erneutes Öffnen der App.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
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
}
