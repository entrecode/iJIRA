import AppKit
import Sparkle

/// Auto-Update via Sparkle. Der appcast ist eine statische Datei im
/// öffentlichen GitHub-Repo (`SUFeedURL` in der Info.plist) — es gibt keinen
/// eigenen Updateserver. Jedes Update ist mit dem privaten EdDSA-Schlüssel
/// signiert und wird gegen `SUPublicEDKey` geprüft.
///
/// Bewusst ohne User-Driver-Delegate: iJIRA ist eine reguläre App mit
/// Dock-Icon, und dafür passt Sparkles Standardverhalten genau — es zeigt ein
/// gefundenes Update erst, wenn der Nutzer ohnehin in der App ist, statt sich
/// in den Vordergrund zu drängen. (Sparkle entscheidet das anhand der
/// Activation Policy zur Laufzeit, siehe `SUApplicationInfo`.)
@MainActor
final class UpdaterController: NSObject, NSMenuItemValidation {
    static let shared = UpdaterController()

    /// `nil`, solange kein öffentlicher Schlüssel konfiguriert ist — siehe
    /// `isConfigured`.
    private var controller: SPUStandardUpdaterController?

    /// Ob Updates überhaupt zur Verfügung stehen (UI blendet sich sonst aus).
    var isAvailable: Bool { controller != nil }

    /// Sparkle meldet eine Fehlkonfiguration mit einem Alert („wenden Sie sich
    /// an den Entwickler"). Ohne eingetragenen Schlüssel — also bei jedem
    /// lokalen Build, solange `scripts/sparkle-setup.sh` nicht gelaufen ist —
    /// wäre das nur Lärm. Deshalb starten wir Sparkle dann gar nicht erst.
    private static var isConfigured: Bool {
        let key = Bundle.main.infoDictionary?["SUPublicEDKey"] as? String
        return !(key ?? "").isEmpty
    }

    private override init() {
        super.init()
        guard Self.isConfigured else {
            Log.app.info("Sparkle: kein SUPublicEDKey — Auto-Update deaktiviert")
            return
        }
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
    }

    /// Menü-Action „Nach Updates suchen …".
    @objc func checkForUpdates(_ sender: Any?) {
        controller?.checkForUpdates(sender)
    }

    var canCheckForUpdates: Bool { controller?.updater.canCheckForUpdates ?? false }

    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    var lastUpdateCheckDate: Date? { controller?.updater.lastUpdateCheckDate }

    /// Graut „Nach Updates suchen …" aus, solange gerade ein Check läuft.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(checkForUpdates(_:)) else { return true }
        return canCheckForUpdates
    }
}
