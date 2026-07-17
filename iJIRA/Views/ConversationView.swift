import AppKit
import SwiftData
import SwiftUI

/// Chat-Verlauf eines Issues: Kommentare als Sprechblasen (eigene rechts,
/// fremde links), Status-/Zuweisungs-Events als zentrierte System-Zeilen.
/// Älteste oben (wie ein Messenger).
struct ConversationView: View {
    let issueKey: String
    let store: NotificationStore
    let appState: AppState

    @Query private var items: [JiraNotification]
    @State private var replyText = ""
    @State private var isSending = false
    @State private var sendError: String?
    @State private var isLoadingOlder = false
    @State private var olderFullyLoaded = false
    @State private var loadOlderError: String?

    init(issueKey: String, store: NotificationStore, appState: AppState) {
        self.issueKey = issueKey
        self.store = store
        self.appState = appState
        _items = Query(filter: #Predicate<JiraNotification> { $0.issueKey == issueKey },
                       sort: \JiraNotification.createdAt, order: .forward)
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider()
            replyBar
        }
        .onAppear { store.markConversationRead(issueKey: issueKey) }
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                issueHeader
                loadOlderRow
                ForEach(items) { item in
                    MessageBubble(notification: item)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }

    /// Die Timeline zeigt nur, was der Sync je gesehen hat — hierüber lässt
    /// sich der Rest der Kommentar-Historie via REST nachziehen.
    @ViewBuilder
    private var loadOlderRow: some View {
        if !olderFullyLoaded {
            VStack(spacing: 2) {
                if isLoadingOlder {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Ältere Kommentare laden") {
                        Task { await loadOlderComments() }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                if let error = loadOlderError {
                    Text(error).font(.caption2).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var issueHeader: some View {
        Button {
            if let url = URL(string: appState.issueWebURL(issueKey)) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(issueKey)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let summary = items.first?.issueSummary {
                        Text(summary)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Reply bar

    private var replyBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                MarkdownTextEditor(text: $replyText)
                    .frame(height: 64)
                if replyText.isEmpty {
                    Text("Antworten… (`code`, ```block```, **fett**, *kursiv*)")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            HStack(spacing: 8) {
                if let error = sendError {
                    Text(error).font(.caption2).foregroundStyle(.red).lineLimit(1)
                }
                Spacer()
                if isSending { ProgressView().controlSize(.small) }
                Button("Senden") { Task { await sendReply() } }
                    .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(12)
    }

    // MARK: - Load older history

    /// Zieht die nächste Seite älterer Kommentare via REST nach. `startAt` ist
    /// die Anzahl bereits bekannter Kommentare — Überlappungen fängt der
    /// `dedupKey` ab. Nachgeladenes gilt als gelesen und wird als `.history`
    /// markiert, damit der Purge es nicht gleich wieder entfernt.
    private func loadOlderComments() async {
        guard !isLoadingOlder, let client = appState.currentClient() else { return }
        isLoadingOlder = true
        loadOlderError = nil
        defer { isLoadingOlder = false }

        let knownComments = items.filter { $0.kind == .comment }.count
        do {
            let page = try await client.commentsPage(issueKey: issueKey, startAt: knownComments)
            for comment in page.comments {
                let isOwn = comment.author?.accountId == appState.accountId
                let author = comment.author?.displayName ?? "jemand"
                var adfJSON: String?
                if let body = comment.body, let data = try? JSONEncoder().encode(body) {
                    adfJSON = String(data: data, encoding: .utf8)
                }
                let notification = JiraNotification(
                    dedupKey: "comment:\(issueKey):\(comment.id)",
                    issueKey: issueKey,
                    issueSummary: items.first?.issueSummary ?? issueKey,
                    kind: .comment,
                    title: "Kommentar von \(author)",
                    bodyPreview: String(comment.bodyText.prefix(280)),
                    actorName: author,
                    actorAvatarURLString: comment.author?.avatar48,
                    webURLString: appState.issueWebURL(issueKey, commentId: comment.id),
                    bodyADFJSON: adfJSON,
                    createdAt: JiraDate.parse(comment.created) ?? .distantPast,
                    receivedAt: Date(),
                    isRead: true,
                    source: .history,
                    isOwn: isOwn)
                store.insertIfNew(notification)
            }
            store.save()

            let total = page.total ?? 0
            if page.comments.isEmpty || knownComments + page.comments.count >= total {
                olderFullyLoaded = true
            }
        } catch {
            loadOlderError = (error as? JiraError)?.userMessage ?? "Laden fehlgeschlagen."
        }
    }

    // MARK: - Send

    private func sendReply() async {
        let trimmed = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let client = appState.currentClient() else { return }

        isSending = true
        sendError = nil
        defer { isSending = false }

        do {
            let comment = try await client.addComment(issueKey: issueKey,
                                                      adfBody: markdownToADFBody(trimmed))

            let displayName: String
            if case .connected(let name, _) = appState.connection { displayName = name }
            else { displayName = "Ich" }

            var adfJSON: String?
            if let body = comment.body, let data = try? JSONEncoder().encode(body) {
                adfJSON = String(data: data, encoding: .utf8)
            }

            let notification = JiraNotification(
                dedupKey: "comment:\(issueKey):\(comment.id)",
                issueKey: issueKey,
                issueSummary: items.first?.issueSummary ?? issueKey,
                kind: .comment,
                title: "Kommentar von \(displayName)",
                bodyPreview: String(trimmed.prefix(280)),
                actorName: displayName,
                actorAvatarURLString: appState.myAvatarURLString,
                webURLString: appState.issueWebURL(issueKey, commentId: comment.id),
                bodyADFJSON: adfJSON,
                createdAt: Date(),
                receivedAt: Date(),
                isRead: true,
                source: .rest,
                isOwn: true
            )
            store.insertIfNew(notification)
            replyText = ""
        } catch {
            sendError = (error as? JiraError)?.userMessage ?? "Senden fehlgeschlagen."
        }
    }
}

// MARK: - Message bubble

private struct MessageBubble: View {
    let notification: JiraNotification

    var body: some View {
        switch notification.kind {
        case .statusChange, .assignment, .fieldChange:
            systemLine
        default:
            commentBubble
        }
    }

    // Zentrierte System-Zeile für Änderungen.
    private var systemLine: some View {
        HStack {
            Spacer()
            VStack(spacing: 2) {
                Text(notification.title).font(.caption.weight(.medium))
                if !notification.bodyPreview.isEmpty {
                    Text(notification.bodyPreview).font(.caption2)
                }
                RelativeTimeText(date: notification.createdAt).font(.caption2).foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(.quaternary.opacity(0.4)))
            Spacer()
        }
    }

    // Kommentar-Sprechblase — eigene rechtsbündig und getönt (Messenger-Optik).
    private var commentBubble: some View {
        HStack(alignment: .top, spacing: 8) {
            if notification.isOwn { Spacer(minLength: 40) }
            if !notification.isOwn {
                AvatarView(url: notification.avatarURL, kind: notification.kind, size: 26)
            }
            VStack(alignment: notification.isOwn ? .trailing : .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(notification.isOwn ? "Ich" : notification.actorName)
                        .font(.caption.weight(.semibold))
                    RelativeTimeText(date: notification.createdAt).font(.caption2).foregroundStyle(.tertiary)
                }
                bodyText
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 12)
                        .fill(notification.isOwn ? AnyShapeStyle(Color.accentColor.opacity(0.18))
                                                 : AnyShapeStyle(.quaternary.opacity(0.35))))
                Button("Im Web öffnen") { open() }
                    .buttonStyle(.link)
                    .font(.caption2)
            }
            if notification.isOwn {
                AvatarView(url: notification.avatarURL, kind: notification.kind, size: 26)
            }
            if !notification.isOwn { Spacer(minLength: 40) }
        }
    }

    @ViewBuilder
    private var bodyText: some View {
        if let rich = renderADF(notification.bodyADFJSON) {
            Text(rich)
        } else {
            Text(notification.bodyPreview.isEmpty ? "(kein Text)" : notification.bodyPreview)
        }
    }

    private func open() {
        if let url = URL(string: notification.webURLString) {
            NSWorkspace.shared.open(url)
        }
    }
}
