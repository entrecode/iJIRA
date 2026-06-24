import Foundation
import SwiftData

/// Besitzt den SwiftData-`ModelContainer` und kapselt alle Lese-/Schreibzugriffe
/// auf die Notification-Timeline. Läuft komplett auf dem Main-Actor — kein
/// Background-Context, um die Nebenläufigkeit einfach zu halten.
@MainActor
final class NotificationStore {
    let container: ModelContainer

    /// Wird nach jeder Mutation mit der aktuellen ungelesen-Anzahl aufgerufen
    /// (Badge-Aktualisierung).
    var unreadDidChange: ((Int) -> Void)?

    private var context: ModelContext { container.mainContext }

    init() {
        let schema = Schema([JiraNotification.self, SyncCursor.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Fallback auf In-Memory, damit die App nie am Store scheitert.
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            container = try! ModelContainer(for: schema, configurations: [memory])
        }
    }

    // MARK: - Cursors

    func cursor(for issueKey: String) -> SyncCursor? {
        let descriptor = FetchDescriptor<SyncCursor>(
            predicate: #Predicate { $0.issueKey == issueKey })
        return try? context.fetch(descriptor).first
    }

    func upsertCursor(issueKey: String, lastSeenUpdated: Date, lastSeenCommentId: String?) {
        if let existing = cursor(for: issueKey) {
            existing.lastSeenUpdated = lastSeenUpdated
            if let lastSeenCommentId { existing.lastSeenCommentId = lastSeenCommentId }
        } else {
            context.insert(SyncCursor(issueKey: issueKey,
                                      lastSeenUpdated: lastSeenUpdated,
                                      lastSeenCommentId: lastSeenCommentId))
        }
    }

    // MARK: - Notifications

    func exists(dedupKey: String) -> Bool {
        let descriptor = FetchDescriptor<JiraNotification>(
            predicate: #Predicate { $0.dedupKey == dedupKey })
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }

    /// Fügt eine Notification ein, falls ihr `dedupKey` noch nicht existiert.
    /// Gibt `true` zurück, wenn tatsächlich neu eingefügt wurde.
    @discardableResult
    func insertIfNew(_ notification: JiraNotification) -> Bool {
        guard !exists(dedupKey: notification.dedupKey) else { return false }
        context.insert(notification)
        return true
    }

    func find(dedupKey: String) -> JiraNotification? {
        let descriptor = FetchDescriptor<JiraNotification>(
            predicate: #Predicate { $0.dedupKey == dedupKey })
        return try? context.fetch(descriptor).first
    }

    func markRead(_ notification: JiraNotification) {
        notification.isRead = true
        save()
    }

    func markConversationRead(issueKey: String) {
        let descriptor = FetchDescriptor<JiraNotification>(
            predicate: #Predicate { $0.issueKey == issueKey && $0.isRead == false })
        let unread = (try? context.fetch(descriptor)) ?? []
        guard !unread.isEmpty else { return }
        unread.forEach { $0.isRead = true }
        save()
    }

    func markAllRead() {
        let descriptor = FetchDescriptor<JiraNotification>(
            predicate: #Predicate { $0.isRead == false })
        for notification in (try? context.fetch(descriptor)) ?? [] {
            notification.isRead = true
        }
        save()
    }

    var unreadCount: Int {
        let descriptor = FetchDescriptor<JiraNotification>(
            predicate: #Predicate { $0.isRead == false })
        return (try? context.fetchCount(descriptor)) ?? 0
    }

    func save() {
        try? context.save()
        unreadDidChange?(unreadCount)
    }
}
