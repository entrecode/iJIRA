import AppKit
import UserNotifications

/// Spiegelt neue Timeline-Einträge als lokale macOS-Notifications ins
/// Notification Center und behandelt deren Actions.
///
/// Delegate-Callbacks der UNUserNotificationCenter laufen nonisolated; alle
/// Zugriffe auf den (Main-Actor-)Store werden dafür auf den Main-Actor gehoben.
final class PushPresenter: NSObject, UNUserNotificationCenterDelegate {
    private let store: NotificationStore
    private let center = UNUserNotificationCenter.current()

    private static let categoryId = "JIRA_NOTIFICATION"
    private static let actionOpen = "OPEN_WEB"
    private static let actionRead = "MARK_READ"

    /// Ab wie vielen neuen Einträgen wir zu einer Sammel-Notification bündeln.
    private static let coalesceThreshold = 5

    init(store: NotificationStore) {
        self.store = store
        super.init()
    }

    // MARK: - Setup

    func registerCategories() {
        let open = UNNotificationAction(identifier: Self.actionOpen,
                                        title: "Im Web öffnen",
                                        options: [.foreground])
        let read = UNNotificationAction(identifier: Self.actionRead,
                                        title: "Als gelesen",
                                        options: [])
        let category = UNNotificationCategory(identifier: Self.categoryId,
                                              actions: [open, read],
                                              intentIdentifiers: [],
                                              options: [])
        center.setNotificationCategories([category])
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
            // Ohne Erlaubnis bleibt die In-App-Timeline + das Menüleisten-Badge.
        }
    }

    // MARK: - Presenting

    @MainActor
    func presentBatch(_ notifications: [JiraNotification]) {
        guard !notifications.isEmpty else { return }
        if notifications.count > Self.coalesceThreshold {
            presentSummary(count: notifications.count)
        } else {
            notifications.forEach(present)
        }
    }

    @MainActor
    private func present(_ notification: JiraNotification) {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.subtitle = "\(notification.issueKey) · \(notification.issueSummary)"
        content.body = notification.bodyPreview
        content.sound = .default
        content.categoryIdentifier = Self.categoryId
        content.userInfo = [
            "dedupKey": notification.dedupKey,
            "webURL": notification.webURLString,
        ]
        // dedupKey als Request-ID: verhindert Dubletten auch auf Systemebene.
        let request = UNNotificationRequest(identifier: notification.dedupKey,
                                            content: content,
                                            trigger: nil)
        center.add(request)
    }

    @MainActor
    private func presentSummary(count: Int) {
        let content = UNMutableNotificationContent()
        content.title = "iJIRA"
        content.body = "\(count) neue Benachrichtigungen"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "summary-\(count)",
                                            content: content,
                                            trigger: nil)
        center.add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Auch im Vordergrund als Banner zeigen.
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let urlString = userInfo["webURL"] as? String
        let dedupKey = userInfo["dedupKey"] as? String
        Task { @MainActor in
            self.handle(action: action, urlString: urlString, dedupKey: dedupKey)
        }
        completionHandler()
    }

    @MainActor
    private func handle(action: String, urlString: String?, dedupKey: String?) {
        switch action {
        case Self.actionRead:
            markRead(dedupKey)
        default:
            // Standard-Tap oder „Im Web öffnen": Issue öffnen + als gelesen markieren.
            if let urlString, let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
            markRead(dedupKey)
        }
    }

    @MainActor
    private func markRead(_ dedupKey: String?) {
        guard let dedupKey, let notification = store.find(dedupKey: dedupKey) else { return }
        store.markRead(notification)
    }
}
