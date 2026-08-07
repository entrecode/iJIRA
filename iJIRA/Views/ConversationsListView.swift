import SwiftData
import SwiftUI

/// Messenger-Inbox: eine Zeile pro Issue, gruppiert aus allen Notifications,
/// neueste Konversation oben. Tippen öffnet den Chat-Verlauf.
struct ConversationsListView: View {
    let onSelect: (String) -> Void

    @Query(sort: \JiraNotification.createdAt, order: .reverse)
    private var notifications: [JiraNotification]

    private var conversations: [Conversation] {
        var order: [String] = []
        var grouped: [String: [JiraNotification]] = [:]
        for notification in notifications {
            if grouped[notification.issueKey] == nil { order.append(notification.issueKey) }
            grouped[notification.issueKey, default: []].append(notification)
        }
        // notifications ist absteigend sortiert → erstes Element je Issue ist das neueste.
        return order.compactMap { key in
            guard let items = grouped[key], let latest = items.first else { return nil }
            return Conversation(issueKey: key,
                                summary: latest.issueSummary,
                                latest: latest,
                                latestComment: items.first { $0.kind == .comment },
                                unread: items.filter { !$0.isRead }.count,
                                total: items.count)
        }
    }

    var body: some View {
        if notifications.isEmpty {
            emptyState
        } else {
            List(conversations) { conversation in
                ConversationRow(conversation: conversation)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(conversation.issueKey) }
            }
            .listStyle(.inset)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bell.slash").font(.largeTitle).foregroundStyle(.secondary)
            Text("Keine Benachrichtigungen").foregroundStyle(.secondary)
            Text("Neue Kommentare und Updates erscheinen hier automatisch.")
                .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

struct Conversation: Identifiable {
    let issueKey: String
    let summary: String
    let latest: JiraNotification
    let latestComment: JiraNotification?
    let unread: Int
    let total: Int
    var id: String { issueKey }

    /// Zeige den letzten Kommentar zusätzlich, wenn das neueste Event selbst
    /// keiner ist (z. B. Kommentar → danach Statuswechsel).
    var extraCommentLine: String? {
        guard latest.kind != .comment, let comment = latestComment else { return nil }
        return comment.bodyPreview.isEmpty ? nil : comment.bodyPreview
    }
}

private struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(url: conversation.latest.avatarURL, kind: conversation.latest.kind)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(conversation.issueKey)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                    Spacer()
                    RelativeTimeText(date: conversation.latest.createdAt)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text(conversation.summary)
                    .font(.subheadline.weight(conversation.unread > 0 ? .semibold : .regular))
                    .lineLimit(1)
                // Konkretes Detail des neuesten Events (Kommentartext, Status A→B, Assignee).
                Text(conversation.latest.listSummary)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                // Zusätzlich der letzte Kommentar, falls er sonst verdeckt wäre.
                if let extra = conversation.extraCommentLine {
                    Label(extra, systemImage: "text.bubble")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if conversation.unread > 0 {
                Text("\(conversation.unread)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor))
            }
        }
        .padding(.vertical, 4)
    }
}

extension Date {
    /// Kurzform relativ zu `reference` (Default: jetzt). Achtung: das Ergebnis
    /// ist ein statischer String und „tickt" nicht von selbst — für Labels in
    /// langlebigen Views `RelativeTimeText` verwenden.
    func relativeShort(to reference: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self, relativeTo: reference)
    }

    /// Genaues Datum samt Uhrzeit („Mittwoch, 5. August 2026 um 10:14") — die
    /// Auflösung hinter jeder relativen Angabe, siehe `RelativeTimeText`.
    ///
    /// Zeitzone bewusst explizit auf Europe/Berlin statt Systemzeit: So nennen
    /// alle im Team dieselbe Uhrzeit, auch wenn jemand gerade woanders sitzt.
    var absoluteLong: String { Date.absoluteFormatter.string(from: self) }

    // Einmal aufgebaut: Formatter sind teuer, und `RelativeTimeText` rendert
    // minütlich neu — je sichtbarer Zeile.
    fileprivate static let absoluteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.timeZone = TimeZone(identifier: "Europe/Berlin")
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return formatter
    }()
}

/// Selbst-aktualisierendes Relativ-Zeitlabel. `RelativeDateTimeFormatter`
/// liefert nur statischen Text (korrekt zur Render-Zeit) — via `TimelineView`
/// rechnen wir ihn minütlich gegen die aktuelle Uhr neu, damit „vor 1 Min."
/// bei geöffnetem Popover nicht stehen bleibt. Font/Farbe erbt der innere
/// `Text` aus der Umgebung.
struct RelativeTimeText: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(date.relativeShort(to: context.date))
        }
        // Mouse-over löst die relative Angabe in Datum + Uhrzeit auf.
        .help(date.absoluteLong)
    }
}
