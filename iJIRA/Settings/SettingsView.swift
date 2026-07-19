import ServiceManagement
import SwiftUI

/// Inhalt des Einstellungs-Fensters.
struct SettingsView: View {
    @Bindable var appState: AppState

    var body: some View {
        TabView {
            ConnectionSettingsView(appState: appState)
                .tabItem { Label("Verbindung", systemImage: "link") }
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

// MARK: - Allgemein

struct GeneralSettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?
    @AppStorage("showWindowOnLaunch") private var showWindowOnLaunch = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Bei Anmeldung starten", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enable in
                    setLaunchAtLogin(enable)
                }
            if let error = launchAtLoginError {
                Text(error).font(.caption2).foregroundStyle(.orange)
            }

            Toggle("Beim Start das Hauptfenster öffnen", isOn: $showWindowOnLaunch)
            Text("Aus = die App startet still in der Menüleiste (empfohlen für den Autostart). Das Hauptfenster öffnet sich jederzeit über das Dock, die Menüleiste oder erneutes Öffnen der App.")
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
