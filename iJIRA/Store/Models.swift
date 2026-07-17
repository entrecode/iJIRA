import Foundation
import SwiftData

enum NotificationKind: String, Codable, Sendable {
    case comment
    case statusChange
    case assignment
    case fieldChange
    case other
}

enum NotificationSourceKind: String, Codable, Sendable {
    case rest
    case bell
    /// Manuell nachgeladene ältere Kommentare (Konversationsansicht) — vom
    /// automatischen Purge ausgenommen.
    case history
}

/// Ein einzelnes Notification-Event in der Timeline. `dedupKey` ist eindeutig,
/// damit dieselbe Änderung über mehrere Sync-Läufe (und Quellen) nur einmal
/// erscheint.
@Model
final class JiraNotification {
    @Attribute(.unique) var dedupKey: String
    var issueKey: String
    var issueSummary: String
    var kindRaw: String
    var title: String
    var bodyPreview: String
    var actorName: String
    var actorAvatarURLString: String?
    var webURLString: String
    /// Roh-ADF des Kommentars als JSON — für reiches Rendering (Mentions/Links)
    /// im Chat-Verlauf. Nil bei Changelog-Events.
    var bodyADFJSON: String?
    var createdAt: Date
    var receivedAt: Date
    var isRead: Bool
    var sourceRaw: String
    /// Vom eigenen Account verfasst (eigener Kommentar). Eigene Nachrichten
    /// erscheinen in der Timeline, sind aber nie ungelesen und werden nie
    /// gepusht. Default `false`, damit bestehende Stores leichtgewichtig
    /// migrieren.
    var isOwn: Bool = false

    init(dedupKey: String,
         issueKey: String,
         issueSummary: String,
         kind: NotificationKind,
         title: String,
         bodyPreview: String,
         actorName: String,
         actorAvatarURLString: String?,
         webURLString: String,
         bodyADFJSON: String? = nil,
         createdAt: Date,
         receivedAt: Date,
         isRead: Bool,
         source: NotificationSourceKind,
         isOwn: Bool = false) {
        self.dedupKey = dedupKey
        self.issueKey = issueKey
        self.issueSummary = issueSummary
        self.kindRaw = kind.rawValue
        self.title = title
        self.bodyPreview = bodyPreview
        self.actorName = actorName
        self.actorAvatarURLString = actorAvatarURLString
        self.webURLString = webURLString
        self.bodyADFJSON = bodyADFJSON
        self.createdAt = createdAt
        self.receivedAt = receivedAt
        self.isRead = isRead
        self.sourceRaw = source.rawValue
        self.isOwn = isOwn
    }

    var kind: NotificationKind { NotificationKind(rawValue: kindRaw) ?? .other }
    var avatarURL: URL? { actorAvatarURLString.flatMap { URL(string: $0) } }

    /// Einzeiler für die Inbox-Vorschau — zeigt das konkrete Detail des Events
    /// (Kommentartext, Status A→B, neuer Assignee) statt nur „X änderte …".
    var listSummary: String {
        switch kind {
        case .comment:
            return bodyPreview.isEmpty ? "Neuer Kommentar" : bodyPreview
        case .statusChange:
            return "Status: \(bodyPreview)"
        case .assignment:
            return bodyPreview
        case .fieldChange, .other:
            return bodyPreview.isEmpty ? title : bodyPreview
        }
    }
}

/// Pro Issue: bis wohin wir bereits synchronisiert haben (Delta-Erkennung).
@Model
final class SyncCursor {
    @Attribute(.unique) var issueKey: String
    var lastSeenUpdated: Date
    var lastSeenCommentId: String?

    init(issueKey: String, lastSeenUpdated: Date, lastSeenCommentId: String?) {
        self.issueKey = issueKey
        self.lastSeenUpdated = lastSeenUpdated
        self.lastSeenCommentId = lastSeenCommentId
    }
}
