import SwiftUI

struct DashboardTaskDetail: View {
    let task: DashboardTask?
    let evidence: [DashboardTaskSourceMessage]
    let isRefreshing: Bool
    let onUpdateStatus: (DashboardTask, DashboardTaskStatus, Date?) -> Void
    let onOpenChat: (Int64) -> Void
    let onClose: () -> Void

    @State private var conversationContext: [DatabaseManager.MessageRecord] = []
    @State private var isLoadingContext = false

    /// Hard cap on the merged Evidence list (source snippets + nearby
    /// chat context). The trigger snippet alone is often opaque, but five
    /// messages is enough to read the surrounding ask without turning the
    /// section into a full chat transcript.
    private static let maxEvidenceRows = 5

    var body: some View {
        DashboardDetailPane(onClose: onClose) {
            if let task {
                DashboardDetailCover {
                    DashboardTopicChip(text: task.topicName ?? "Uncategorized", tint: topicTint(for: task))
                    Text(task.title)
                        .font(PidgyDashboardTheme.taskDetailTitleFont)
                        .tracking(-0.4)
                        .foregroundStyle(PidgyDashboardTheme.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        DashboardPriorityDot(priority: task.priority)
                        Text("\(task.priority.label) priority")
                            .font(PidgyDashboardTheme.metadataMediumFont)
                        Text("·")
                        Text(task.chatTitle)
                        if !displayPerson(for: task).isEmpty {
                            Text("·")
                            Text(displayPerson(for: task))
                                .fontWeight(.medium)
                        }
                    }
                    .font(PidgyDashboardTheme.metadataFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                }

                if !task.suggestedAction.isEmpty {
                    DashboardDetailSection(
                        title: "Suggested action",
                        trailing: "conf \(Int((task.confidence * 100).rounded()))%"
                    ) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Pidgy says")
                                .font(PidgyDashboardTheme.detailBodyFont)
                                .italic()
                                .foregroundStyle(PidgyDashboardTheme.blue)
                            Text(task.suggestedAction)
                                .font(PidgyDashboardTheme.detailBodyFont)
                                .foregroundStyle(PidgyDashboardTheme.primary)
                                .lineSpacing(3)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(PidgyDashboardTheme.paper)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(PidgyDashboardTheme.rule)
                        )
                    }
                }

                DashboardDetailSection(title: "Summary") {
                    Text(task.summary.isEmpty ? "No summary available." : task.summary)
                        .font(PidgyDashboardTheme.detailBodyFont)
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                        .lineSpacing(3)
                }

                let merged = mergedEvidenceItems()
                DashboardDetailSection(
                    title: "Evidence",
                    trailing: evidenceTrailing(for: merged)
                ) {
                    VStack(spacing: 6) {
                        if merged.isEmpty {
                            Text(isLoadingContext
                                 ? "Loading nearby messages…"
                                 : "No source snippets were stored for this task.")
                                .font(PidgyDashboardTheme.detailBodyFont)
                                .foregroundStyle(PidgyDashboardTheme.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ForEach(merged) { item in
                                DashboardEvidenceContextRow(item: item)
                            }
                        }
                    }
                }
            } else if isRefreshing {
                VStack(alignment: .leading, spacing: 22) {
                    DashboardSkeletonHeader()
                    DashboardSkeletonTextBlock(lineCount: 3)
                    DashboardSkeletonRows(count: 4, showTimestamp: false)
                }
                .padding(.top, 18)
            } else {
                DashboardEmptyState(
                    systemImage: "tray",
                    title: "No task selected",
                    subtitle: "Choose a task to inspect evidence and act on it."
                )
            }
        } actions: {
            // Single primary action only — Mark Done when a task is
            // selected, nothing when the empty state is shown. The global
            // top-bar Refresh covers re-evaluation; no per-detail Refresh.
            if let task {
                Button {
                    onUpdateStatus(task, .done, nil)
                } label: {
                    Label("Mark Done", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .background(DashboardCapsuleBackground())
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .foregroundStyle(PidgyDashboardTheme.primary)
        .task(id: task?.id) {
            await loadConversationContext()
        }
    }

    private func displayPerson(for task: DashboardTask) -> String {
        task.personName.isEmpty ? task.ownerName : task.personName
    }

    private func loadConversationContext() async {
        guard let chatId = task?.chatId else {
            conversationContext = []
            return
        }
        isLoadingContext = true
        defer { isLoadingContext = false }
        // Pull a few extra so after deduping against source snippets we
        // still have enough non-source rows to fill the merged list.
        let recent = await DatabaseManager.shared.loadMessages(
            chatId: chatId,
            limit: Self.maxEvidenceRows + 4
        )
        conversationContext = recent.sorted { $0.date < $1.date }
    }

    /// Combines source snippets (always shown) with a few surrounding chat
    /// messages, sorted chronologically and capped at `maxEvidenceRows`.
    /// Source snippets get priority — if there are 5 of them, no extra
    /// context is added; if there's 1, we fill the rest with the most
    /// recent context messages.
    private func mergedEvidenceItems() -> [EvidenceContextItem] {
        let sourceItems = evidence.map { source in
            EvidenceContextItem(
                id: source.messageId,
                date: source.date,
                senderName: source.senderName,
                isOutgoing: false,
                text: source.text,
                isSource: true
            )
        }

        let evidenceIds = Set(evidence.map(\.messageId))
        let contextItems = conversationContext
            .filter { !evidenceIds.contains($0.id) }
            .map { record in
                EvidenceContextItem(
                    id: record.id,
                    date: record.date,
                    senderName: record.isOutgoing
                        ? "You"
                        : (record.senderName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                           ? (record.senderName ?? "")
                           : "Unknown"),
                    isOutgoing: record.isOutgoing,
                    text: nonEmptyDisplayText(for: record),
                    isSource: false
                )
            }

        let cap = Self.maxEvidenceRows
        let sourceCapped = Array(sourceItems.prefix(cap))
        let remaining = max(0, cap - sourceCapped.count)
        // Take the most recent context messages so the user sees the
        // freshest surrounding conversation.
        let contextTrailing = Array(contextItems.suffix(remaining))

        return (sourceCapped + contextTrailing).sorted { $0.date < $1.date }
    }

    private func nonEmptyDisplayText(for record: DatabaseManager.MessageRecord) -> String {
        let trimmed = record.textContent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        if let media = record.mediaTypeRaw, !media.isEmpty {
            return "[\(media)]"
        }
        return "[empty]"
    }

    private func evidenceTrailing(for merged: [EvidenceContextItem]) -> String {
        let sourceCount = evidence.count
        let contextCount = merged.count - merged.filter(\.isSource).count
        if sourceCount == 0 && contextCount == 0 {
            return isLoadingContext ? "loading…" : "no snippets"
        }
        if contextCount == 0 {
            return "\(sourceCount) snippet\(sourceCount == 1 ? "" : "s")"
        }
        return "\(sourceCount) source · \(contextCount) context"
    }
}

struct EvidenceContextItem: Identifiable, Equatable {
    let id: Int64
    let date: Date
    let senderName: String
    let isOutgoing: Bool
    let text: String
    let isSource: Bool
}

struct DashboardEvidenceContextRow: View {
    let item: EvidenceContextItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Left gutter — bright on the source message that drove
            // extraction, faint on surrounding context messages.
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(item.isSource ? PidgyDashboardTheme.brand : Color.Pidgy.border2)
                .frame(width: 2)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.senderName)
                        .font(PidgyDashboardTheme.metadataMediumFont)
                        .foregroundStyle(item.isOutgoing
                            ? PidgyDashboardTheme.brand
                            : PidgyDashboardTheme.primary)
                    Text(DateFormatting.compactRelativeTime(from: item.date))
                        .font(PidgyDashboardTheme.monoCaptionFont)
                        .foregroundStyle(PidgyDashboardTheme.tertiary)
                    if item.isSource {
                        Text("source")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.6)
                            .textCase(.uppercase)
                            .foregroundStyle(PidgyDashboardTheme.brand)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .stroke(PidgyDashboardTheme.brand.opacity(0.4), lineWidth: 1)
                            )
                    }
                    Spacer()
                }
                Text(item.text)
                    .font(PidgyDashboardTheme.detailBodyFont)
                    .foregroundStyle(item.isSource
                        ? PidgyDashboardTheme.primary
                        : PidgyDashboardTheme.secondary)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(item.isSource
                      ? PidgyDashboardTheme.brand.opacity(0.06)
                      : Color.clear)
        )
    }
}


struct DashboardPersonDetail: View {
    @EnvironmentObject private var telegramService: TelegramService
    @EnvironmentObject private var aiService: AIService
    @ObservedObject private var profileService = PersonProfileService.shared

    let contact: RelationGraph.Node?
    let signal: DashboardPersonSignal?
    let tasks: [DashboardTask]
    let followUpItems: [FollowUpItem]
    let onOpenTask: (DashboardTask) -> Void
    let onOpenChat: (TGChat) -> Void
    let onClose: () -> Void

    @State private var recentMessages: [DashboardPersonRecentMessage] = []
    @State private var isLoadingRecentMessages = false

    var body: some View {
        DashboardDetailPane(onClose: onClose) {
            if let contact {
                DashboardDetailCover {
                    HStack(alignment: .top, spacing: 14) {
                        DashboardTelegramAvatar(
                            chat: privateChat(for: contact),
                            fallbackTitle: contact.bestDisplayName,
                            size: 44
                        )
                        VStack(alignment: .leading, spacing: 5) {
                            Text(contact.bestDisplayName)
                                .font(PidgyDashboardTheme.titleFont)
                                .foregroundStyle(PidgyDashboardTheme.primary)
                            Text("\(contact.category) · score \(Int(contact.interactionScore.rounded()))")
                                .font(PidgyDashboardTheme.metadataFont)
                                .foregroundStyle(PidgyDashboardTheme.secondary)
                            Text("last touched \(contact.lastInteractionAt.map(DateFormatting.compactRelativeTime(from:)) ?? "never") ago")
                                .font(PidgyDashboardTheme.metadataFont)
                                .foregroundStyle(PidgyDashboardTheme.secondary)
                        }
                    }
                }

                if let profileSnapshot = profileService.profilesByUserId[contact.entityId],
                   !profileSnapshot.summary.isEmpty {
                    DashboardPersonAIProfileSection(snapshot: profileSnapshot)
                } else if aiService.isConfigured {
                    DashboardPersonAIProfileSection(
                        snapshot: PersonProfileSnapshot(
                            userId: contact.entityId,
                            summary: "",
                            isLoading: true,
                            lastExtractedAt: nil
                        )
                    )
                }

                if let personSummary {
                    DashboardPersonSummarySection(
                        summary: personSummary,
                        isLoading: isLoadingRecentMessages
                    )
                }

                HStack(alignment: .top, spacing: 0) {
                    DashboardPersonColumn(title: "Tasks", count: tasks.count) {
                        if tasks.isEmpty {
                            DashboardSmallEmptyText("No open tasks tied to this person.")
                        } else {
                            ForEach(tasks.prefix(8)) { task in
                                Button {
                                    onOpenTask(task)
                                } label: {
                                    DashboardMiniTaskRow(task: task)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Rectangle()
                        .fill(PidgyDashboardTheme.rule)
                        .frame(width: 1)

                    DashboardPersonColumn(title: "Reply queue", count: followUpItems.count) {
                        if followUpItems.isEmpty {
                            DashboardSmallEmptyText("Nothing pending.")
                        } else {
                            ForEach(followUpItems.prefix(8), id: \.chat.id) { item in
                                Button {
                                    onOpenChat(item.chat)
                                } label: {
                                    DashboardMiniReplyRow(item: item)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

            } else {
                DashboardEmptyState(
                    systemImage: "person.2",
                    title: "No people yet",
                    subtitle: "Relation graph data appears here after indexing."
                )
            }
        } actions: {
            if let item = followUpItems.first {
                Button {
                    onOpenChat(item.chat)
                } label: {
                    Label("Open latest chat", systemImage: "paperplane")
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(DashboardCapsuleBackground())
            }
        }
        .foregroundStyle(PidgyDashboardTheme.primary)
        .task(id: contact?.entityId) {
            await loadRecentMessages(for: contact)
            await loadAIProfile(for: contact)
        }
    }

    private func loadAIProfile(for contact: RelationGraph.Node?) async {
        guard let contact, aiService.isConfigured else { return }
        let myUserId = telegramService.currentUser?.id ?? 0
        let chatTitleResolver: (Int64) -> String = { [weak telegramService] chatId in
            guard let telegramService else { return "" }
            if let chat = (telegramService.visibleChats + telegramService.chats).first(where: { $0.id == chatId }) {
                return chat.title
            }
            return ""
        }
        _ = await profileService.loadProfile(
            userId: contact.entityId,
            personName: contact.bestDisplayName,
            aiService: aiService,
            myUserId: myUserId,
            chatTitleResolver: chatTitleResolver
        )
    }

    private var personSummary: DashboardPersonContextSummary? {
        guard let contact else { return nil }
        return DashboardPersonContextSummary.make(
            contact: contact,
            openTaskCount: signal?.openTaskCount ?? tasks.count,
            openReplyCount: signal?.openReplyCount ?? followUpItems.count,
            messages: recentMessages
        )
    }

    private func privateChat(for contact: RelationGraph.Node) -> TGChat? {
        allChats.first { chat in
            guard case .privateChat(let userId) = chat.chatType else { return false }
            return userId == contact.entityId
        }
    }

    private var allChats: [TGChat] {
        let allChats = telegramService.visibleChats + telegramService.chats
        var seen = Set<Int64>()
        return allChats.filter { seen.insert($0.id).inserted }
    }

    private func loadRecentMessages(for contact: RelationGraph.Node?) async {
        guard let contact else {
            recentMessages = []
            return
        }

        isLoadingRecentMessages = true
        defer { isLoadingRecentMessages = false }

        var records: [DatabaseManager.MessageRecord] = []
        if let privateChat = privateChat(for: contact) {
            records += await DatabaseManager.shared.loadMessages(chatId: privateChat.id, limit: 16)
        }

        records += await DatabaseManager.shared.loadMessagesMatchingSenderTerms(
            senderTerms: searchTerms(for: contact),
            startDate: nil,
            endDate: nil,
            limit: 24
        )

        recentMessages = makeRecentMessages(from: records)
    }

    private func makeRecentMessages(from records: [DatabaseManager.MessageRecord]) -> [DashboardPersonRecentMessage] {
        var seen = Set<String>()
        return records
            .sorted {
                if $0.date != $1.date { return $0.date > $1.date }
                return $0.id > $1.id
            }
            .compactMap { record -> DashboardPersonRecentMessage? in
                let key = "\(record.chatId):\(record.id)"
                guard seen.insert(key).inserted else { return nil }
                let rawText = record.textContent ?? record.mediaTypeRaw.map { "[\($0)]" } ?? ""
                let text = rawText
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return DashboardPersonRecentMessage(
                    chatId: record.chatId,
                    chatTitle: chatTitle(for: record.chatId),
                    senderName: record.isOutgoing ? "You" : (record.senderName ?? "Unknown"),
                    text: text,
                    date: record.date,
                    isOutgoing: record.isOutgoing
                )
            }
            .prefix(12)
            .map { $0 }
    }

    private func chatTitle(for chatId: Int64) -> String {
        if let chat = allChats.first(where: { $0.id == chatId }) {
            return chat.title
        }
        if let task = tasks.first(where: { $0.chatId == chatId }) {
            return task.chatTitle
        }
        if let item = followUpItems.first(where: { $0.chat.id == chatId }) {
            return item.chat.title
        }
        return "Chat \(chatId)"
    }

    private func searchTerms(for contact: RelationGraph.Node) -> [String] {
        var terms: [String] = []
        for value in [contact.bestDisplayName, contact.displayName, contact.username] {
            guard let value else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 3 else { continue }
            terms.append(trimmed)
            if let first = trimmed.split(separator: " ").first, first.count >= 3 {
                terms.append(String(first))
            }
        }
        var seen = Set<String>()
        return terms.filter { seen.insert($0.lowercased()).inserted }
    }
}

struct DashboardPersonAIProfileSection: View {
    let snapshot: PersonProfileSnapshot

    var body: some View {
        DashboardDetailSection(title: "Profile") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: snapshot.isLoading ? "arrow.clockwise" : "sparkles")
                        .font(PidgyDashboardTheme.metadataMediumFont)
                        .foregroundStyle(PidgyDashboardTheme.blue)
                        .frame(width: 18, height: 18)
                    if snapshot.summary.isEmpty && snapshot.isLoading {
                        Text("Building profile from recent messages…")
                            .font(PidgyDashboardTheme.metadataFont)
                            .foregroundStyle(PidgyDashboardTheme.secondary)
                    } else {
                        // `Text(LocalizedStringKey:)` renders inline
                        // `**bold**` markdown for the section labels
                        // the prompt emits (`**Who:**`, `**Vibe:**`, etc.).
                        Text(LocalizedStringKey(snapshot.summary))
                            .font(PidgyDashboardTheme.metadataFont)
                            .foregroundStyle(PidgyDashboardTheme.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(3)
                    }
                }
                if let extractedAt = snapshot.lastExtractedAt {
                    Text("Updated \(DateFormatting.compactRelativeTime(from: extractedAt)) ago")
                        .font(PidgyDashboardTheme.captionFont)
                        .foregroundStyle(PidgyDashboardTheme.tertiary)
                }
            }
        }
    }
}

struct DashboardPersonSummarySection: View {
    let summary: DashboardPersonContextSummary
    let isLoading: Bool

    var body: some View {
        DashboardDetailSection(title: "Relationship context") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: isLoading ? "arrow.clockwise" : "sparkles")
                        .font(PidgyDashboardTheme.metadataMediumFont)
                        .foregroundStyle(PidgyDashboardTheme.blue)
                        .frame(width: 18, height: 18)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(summary.headline)
                            .font(PidgyDashboardTheme.metadataMediumFont)
                            .foregroundStyle(PidgyDashboardTheme.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(summary.detail)
                            .font(PidgyDashboardTheme.metadataFont)
                            .foregroundStyle(PidgyDashboardTheme.secondary)
                    }
                }

                if summary.snippets.isEmpty {
                    DashboardSmallEmptyText("No indexed snippets for this person yet.")
                } else {
                    VStack(spacing: 8) {
                        ForEach(summary.snippets.prefix(4)) { snippet in
                            DashboardPersonSnippetRow(snippet: snippet)
                        }
                    }
                }
            }
        }
    }
}

struct DashboardPersonSnippetRow: View {
    let snippet: DashboardPersonRecentMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(snippet.senderName)
                    .font(PidgyDashboardTheme.captionMediumFont)
                    .foregroundStyle(snippet.isOutgoing ? PidgyDashboardTheme.blue : PidgyDashboardTheme.primary)
                    .lineLimit(1)
                Text("·")
                    .foregroundStyle(PidgyDashboardTheme.tertiary)
                Text(snippet.chatTitle)
                    .font(PidgyDashboardTheme.captionFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(DateFormatting.dashboardListTimestamp(from: snippet.date))
                    .font(PidgyDashboardTheme.monoCaptionFont)
                    .foregroundStyle(PidgyDashboardTheme.tertiary)
                    .lineLimit(1)
            }

            Text(snippet.text)
                .font(PidgyDashboardTheme.metadataFont)
                .foregroundStyle(PidgyDashboardTheme.secondary)
                .lineLimit(2)
                .lineSpacing(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PidgyDashboardTheme.paper)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(PidgyDashboardTheme.rule)
        )
    }
}
