import AppKit
import SwiftUI

// MARK: - Titel

struct IssueTitleSection: View {
    @Bindable var model: IssueDetailModel
    let detail: IssueDetailDTO

    var body: some View {
        Text(detail.fields.summary)
            .font(.title2.weight(.semibold))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Meta (Assignee, Parent, Reporter)

struct IssueMetaSection: View {
    @Bindable var model: IssueDetailModel
    let detail: IssueDetailDTO

    var body: some View {
        SectionCard(title: "Details", systemImage: "list.bullet.rectangle") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    metaLabel("Assignee")
                    userChip(detail.fields.assignee, emptyText: "Nicht zugewiesen")
                }
                GridRow {
                    metaLabel("Parent")
                    parentChip
                }
                if let reporter = detail.fields.reporter {
                    GridRow {
                        metaLabel("Reporter")
                        userChip(reporter, emptyText: "—")
                    }
                }
            }
        }
    }

    private func metaLabel(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.leading)
            .frame(minWidth: 70, alignment: .leading)
    }

    @ViewBuilder
    private func userChip(_ user: UserDTO?, emptyText: String) -> some View {
        if let user {
            HStack(spacing: 6) {
                AvatarView(url: user.avatar48.flatMap { URL(string: $0) }, kind: .comment, size: 20)
                Text(user.displayName ?? "?").font(.callout)
            }
        } else {
            Text(emptyText).font(.callout).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var parentChip: some View {
        if let parent = detail.fields.parent {
            Button {
                IssueWindowManager.shared.open(issueKey: parent.key)
            } label: {
                HStack(spacing: 6) {
                    Text(parent.key)
                        .font(.system(.callout, design: .monospaced).weight(.medium))
                        .foregroundStyle(.tint)
                    if let summary = parent.fields?.summary {
                        Text(summary).font(.callout).lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Parent öffnen")
        } else {
            Text("Kein Parent").font(.callout).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Beschreibung

struct IssueDescriptionSection: View {
    @Bindable var model: IssueDetailModel
    let detail: IssueDetailDTO

    var body: some View {
        SectionCard(title: "Beschreibung", systemImage: "text.alignleft") {
            if let description = detail.fields.description {
                ADFContentView(
                    document: description,
                    resolveAttachment: { model.attachment(forMediaAlt: $0) },
                    thumbnail: { model.thumbnail(for: $0) },
                    onOpenAttachment: { model.openAttachment($0) })
            } else {
                Text("Keine Beschreibung")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Anhänge

struct IssueAttachmentsSection: View {
    @Bindable var model: IssueDetailModel

    var body: some View {
        SectionCard(title: "Anhänge (\(model.attachments.count))", systemImage: "paperclip") {
            FlowLayoutLite(spacing: 8) {
                ForEach(model.attachments) { attachment in
                    AttachmentTile(attachment: attachment,
                                   image: model.thumbnail(for: attachment),
                                   onOpen: { model.openAttachment(attachment) })
                        .overlay(alignment: .topTrailing) {
                            if model.openingAttachments.contains(attachment.id) {
                                ProgressView().controlSize(.small).padding(4)
                            }
                        }
                }
            }
        }
    }
}

// MARK: - Verlinkte Vorgänge

struct IssueLinksSection: View {
    @Bindable var model: IssueDetailModel
    let detail: IssueDetailDTO

    var body: some View {
        SectionCard(title: "Verlinkte Vorgänge", systemImage: "link") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(detail.fields.issuelinks ?? []) { link in
                    if let other = link.other {
                        linkRow(link: link, other: other)
                    }
                }
            }
        }
    }

    private func linkRow(link: IssueLinkDTO,
                         other: (issue: LinkedIssueDTO, label: String)) -> some View {
        HStack(spacing: 8) {
            Text(other.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 90, alignment: .leading)
            Button {
                IssueWindowManager.shared.open(issueKey: other.issue.key)
            } label: {
                HStack(spacing: 6) {
                    Text(other.issue.key)
                        .font(.system(.callout, design: .monospaced).weight(.medium))
                        .foregroundStyle(.tint)
                    Text(other.issue.fields?.summary ?? "")
                        .font(.callout)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            if let status = other.issue.fields?.status {
                StatusBadge(status: status)
            }
        }
    }
}

// MARK: - Kommentare

struct IssueCommentsSection: View {
    @Bindable var model: IssueDetailModel

    @State private var draft = ""
    @State private var isSending = false

    var body: some View {
        SectionCard(title: "Kommentare (\(model.comments.count))", systemImage: "text.bubble") {
            VStack(alignment: .leading, spacing: 14) {
                if model.comments.isEmpty {
                    Text("Noch keine Kommentare")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                ForEach(model.comments, id: \.id) { comment in
                    CommentRow(model: model, comment: comment)
                }
                composer
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            ZStack(alignment: .topLeading) {
                MarkdownTextEditor(text: $draft)
                    .frame(height: 76)
                if draft.isEmpty {
                    Text("Kommentieren… (`code`, **fett**, *kursiv*, @Name, ONE-123)")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            HStack {
                Spacer()
                if isSending { ProgressView().controlSize(.small) }
                Button("Senden") {
                    Task { await send() }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
            }
        }
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSending = true
        defer { isSending = false }
        if await model.addComment(markdown: text) {
            draft = ""
        }
    }
}

private struct CommentRow: View {
    @Bindable var model: IssueDetailModel
    let comment: CommentDTO

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            AvatarView(url: comment.author?.avatar48.flatMap { URL(string: $0) },
                       kind: .comment, size: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(comment.author?.displayName ?? "jemand")
                        .font(.caption.weight(.semibold))
                    if let created = JiraDate.parse(comment.created) {
                        RelativeTimeText(date: created)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                if let body = comment.body {
                    ADFContentView(
                        document: body,
                        resolveAttachment: { model.attachment(forMediaAlt: $0) },
                        thumbnail: { model.thumbnail(for: $0) },
                        onOpenAttachment: { model.openAttachment($0) })
                }
            }
        }
    }
}
