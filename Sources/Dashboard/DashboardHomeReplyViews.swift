import SwiftUI

struct DashboardHomePage: View {
    let tasks: [DashboardTask]
    let followUpItems: [FollowUpItem]
    let isLoading: Bool
    let aiConfigured: Bool
    let onOpenTask: (DashboardTask) -> Void
    let onOpenReply: (FollowUpItem) -> Void

    private var feedItems: [DashboardFeedItem] {
        let taskItems = tasks
            .filter(\.isActionableNow)
            .map(DashboardFeedItem.task)
        let replyItems = followUpItems.map(DashboardFeedItem.reply)
        return (taskItems + replyItems)
            .sorted {
                if $0.section.rank != $1.section.rank {
                    return $0.section.rank < $1.section.rank
                }
                if $0.date != $1.date {
                    return $0.date > $1.date
                }
                // Stable tiebreaker — when two items share both section and
                // date (common: tasks from the same minute), the previous
                // comparator left ordering implementation-defined. That made
                // the list visibly shuffle on every upstream republish
                // (AttentionStore upserts, ChatPhotoManager photo loads,
                // TaskIndex ticks) — Devesh saw it as flicker on his build.
                return $0.id < $1.id
            }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Hero header — flush-left with the outer page padding.
                // Removed the +12 inner wrapper that was making the
                // title sit further right than the row avatars below
                // (Dashboard.jsx puts hero text at body x=0 and the
                // eyebrow + row content at body x=8, so the hero
                // intentionally hugs the left more tightly).
                //
                // Inner spacings now match the design: 6pt between
                // title and subtitle, 10pt subtitle-to-squiggle (4 from
                // VStack + 6 from squiggle's padding-top), and the
                // squiggle has 4pt below so the first group sits 4+28
                // away from the squiggle baseline.
                VStack(alignment: .leading, spacing: 6) {
                    Text("What to do now")
                        .font(PidgyDashboardTheme.heroTitleFont)
                        .tracking(-0.7)
                        .foregroundStyle(PidgyDashboardTheme.primary)
                    Text("\(feedItems.count) active item\(feedItems.count == 1 ? "" : "s")")
                        .font(PidgyDashboardTheme.pageSubtitleFont)
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                    DashboardPigeonFlock()
                        .padding(.top, 4)
                }
                .padding(.bottom, 4)

                if feedItems.isEmpty && isLoading {
                    DashboardSkeletonRows(count: 7)
                        .padding(.top, 6)
                } else if feedItems.isEmpty {
                    DashboardEmptyState(
                        systemImage: aiConfigured ? "checkmark.circle" : "sparkles",
                        title: aiConfigured ? "Nothing urgent right now" : "Task extraction is off",
                        subtitle: aiConfigured
                            ? "Reply queue and tasks will appear here when Pidgy finds active work."
                            : "Reply queue still works. Connect an AI provider to fill tasks."
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 36)
                } else {
                    // Hoisted from per-section to the whole feed: the prior
                    // .animation(nil, value: items.map(\.id)) scope only
                    // covered intra-section reorders. During the initial
                    // pipeline burst the AttentionStore upserts ~20 chats as
                    // their AI category lands, and many of those flip
                    // sections (cached quiet → on_me, etc.). The cross-section
                    // move — disappear from A's VStack + appear in B's VStack
                    // — and the first-item-arrives section-header pop-in both
                    // sit *outside* a per-section animation modifier, so they
                    // leaked through as a visible flicker for the first few
                    // seconds. Suppressing animations on the whole feed
                    // covers both cases.
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(DashboardFeedSection.allCases) { section in
                            let items = feedItems.filter { $0.section == section }
                            if !items.isEmpty {
                                // Design's `group: { marginTop: 28 }`
                                // gives every section a generous gap.
                                // The label's own `.padding(.leading, 8)`
                                // does the horizontal alignment with
                                // the row avatars, so this only needs
                                // to handle vertical rhythm.
                                DashboardSectionLabel(section.title)
                                    .padding(.top, 28)
                                    .padding(.bottom, 6)

                                VStack(spacing: 0) {
                                    ForEach(items.prefix(section == .onFire ? 5 : 10)) { item in
                                        Button {
                                            switch item.kind {
                                            case .task(let task):
                                                onOpenTask(task)
                                            case .reply(let reply):
                                                onOpenReply(reply)
                                            }
                                        } label: {
                                            DashboardFeedRow(item: item)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                    .animation(nil, value: feedItems.map(\.id))
                    .transaction { $0.disablesAnimations = true }
                }
            }
            .frame(maxWidth: PidgyDashboardTheme.pageMaxWidth, alignment: .leading)
            .padding(.top, PidgyDashboardTheme.pageTopPadding)
            .padding(.horizontal, PidgyDashboardTheme.pageHorizontalPadding)
            .padding(.bottom, PidgyDashboardTheme.pageBottomPadding)
            .frame(maxWidth: .infinity)
        }
        .background(PidgyDashboardTheme.paper)
    }
}

struct DashboardReplyQueuePage: View {
    let items: [FollowUpItem]
    let isLoading: Bool
    let processedCount: Int
    let totalCount: Int
    @Binding var selectedChatId: Int64?
    /// Incremental refresh — only entry point for re-analysis. Top-bar
    /// button only; detail panes have no Refresh of their own. Only
    /// analyzes chats with new messages since their cached decision.
    let onRefresh: () -> Void
    let onOpenChat: (TGChat) -> Void

    @State private var filter: DashboardReplyFilter = .onMe

    private var filteredItems: [FollowUpItem] {
        switch filter {
        case .onMe:
            return items.filter { $0.category == .onMe }
        case .onThem:
            return items.filter { $0.category == .onThem }
        case .quiet:
            return items.filter { $0.category == .quiet }
        }
    }

    private var selectedItem: FollowUpItem? {
        selectedChatId.flatMap { id in filteredItems.first { $0.chat.id == id } }
    }

    var body: some View {
        if let selectedItem {
            HStack(spacing: 0) {
                compactList
                    .frame(minWidth: 460)

                DashboardReplyDetail(
                    item: selectedItem,
                    onOpenChat: onOpenChat,
                    onClose: { selectedChatId = nil }
                )
                .frame(width: 420)
            }
        } else {
            centeredList
        }
    }

    private var centeredList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                queueRows
            }
            .frame(maxWidth: PidgyDashboardTheme.pageMaxWidth, alignment: .leading)
            .padding(.top, PidgyDashboardTheme.pageTopPadding)
            .padding(.horizontal, PidgyDashboardTheme.pageHorizontalPadding)
            .padding(.bottom, PidgyDashboardTheme.pageBottomPadding)
            .frame(maxWidth: .infinity)
        }
    }

    private var compactList: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 28)
                .padding(.bottom, 14)

            ScrollView {
                queueRows
                    .padding(.horizontal, 14)
                    .padding(.bottom, 28)
            }
        }
        .background(PidgyDashboardTheme.paper)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Reply queue")
                    .font(PidgyDashboardTheme.pageTitleFont)
                    .tracking(-0.6)
                    .foregroundStyle(PidgyDashboardTheme.primary)
                if isLoading, totalCount > 0 {
                    Text("Analyzing \(processedCount)/\(totalCount) chats")
                        .font(PidgyDashboardTheme.pageSubtitleFont)
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                }
            }

            Spacer()

            DashboardSegmentedReplyFilter(
                selection: $filter,
                onMeCount: items.filter { $0.category == .onMe }.count,
                onThemCount: items.filter { $0.category == .onThem }.count,
                quietCount: items.filter { $0.category == .quiet }.count
            )
        }
        .padding(selectedItem == nil ? EdgeInsets(top: 0, leading: 8, bottom: 22, trailing: 8) : EdgeInsets())
    }

    private var queueRows: some View {
        VStack(spacing: 0) {
            if filteredItems.isEmpty && isLoading {
                DashboardSkeletonRows(count: selectedItem == nil ? 9 : 7)
                    .padding(.top, 6)
            } else if filteredItems.isEmpty {
                DashboardEmptyState(
                    systemImage: "checkmark.circle",
                    title: "No matching chats",
                    subtitle: "Try a different tab or refresh."
                )
                .frame(maxWidth: .infinity)
                .padding(.top, 36)
            } else {
                ForEach(filteredItems, id: \.chat.id) { item in
                    Button {
                        selectedChatId = item.chat.id
                    } label: {
                        DashboardAttentionRow(
                            item: item,
                            isSelected: selectedChatId == item.chat.id
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct DashboardReplyDetail: View {
    let item: FollowUpItem?
    let onOpenChat: (TGChat) -> Void
    let onClose: () -> Void

    @State private var conversationContext: [DatabaseManager.MessageRecord] = []
    @State private var isLoadingContext = false

    /// Same cap as the Task Evidence section — enough to read the back-and-
    /// forth that triggered the suggestion without becoming a full transcript.
    private static let maxEvidenceRows = 5

    var body: some View {
        DashboardDetailPane(onClose: onClose) {
            if let item {
                DashboardDetailCover {
                    DashboardTopicChip(text: item.category.rawValue, tint: categoryTint(item.category))
                    Text(item.chat.title)
                        .font(PidgyDashboardTheme.sectionTitleFont)
                        .tracking(-0.4)
                        .foregroundStyle(PidgyDashboardTheme.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Text(item.chat.chatType.displayName)
                        Text("·")
                        Text(item.lastMessage.relativeDate)
                    }
                    .font(PidgyDashboardTheme.metadataFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                }

                DashboardDetailSection(title: "Suggested action") {
                    Text(item.suggestedAction ?? "No suggested action.")
                        .font(PidgyDashboardTheme.detailBodyFont)
                        .foregroundStyle(PidgyDashboardTheme.primary)
                        .lineSpacing(3)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(PidgyDashboardTheme.paper)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(PidgyDashboardTheme.rule)
                        )
                }

                let evidenceItems = mergedEvidenceItems(for: item)
                DashboardDetailSection(
                    title: "Evidence",
                    trailing: evidenceTrailing(for: evidenceItems)
                ) {
                    VStack(spacing: 6) {
                        if evidenceItems.isEmpty {
                            Text(isLoadingContext
                                 ? "Loading nearby messages…"
                                 : "No recent messages found for this chat.")
                                .font(PidgyDashboardTheme.detailBodyFont)
                                .foregroundStyle(PidgyDashboardTheme.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ForEach(evidenceItems) { row in
                                DashboardEvidenceContextRow(item: row)
                            }
                        }
                    }
                }
            } else {
                DashboardEmptyState(
                    systemImage: "arrowshape.turn.up.left",
                    title: "Nothing selected",
                    subtitle: "Choose a conversation to inspect its latest context."
                )
            }
        } actions: {
            // Single primary action — the top-bar Refresh covers re-analysis.
            // Per-detail Refresh buttons were removed because the global
            // top-bar refresh is the one source of truth for the user.
            Button {
                if let item { onOpenChat(item.chat) }
            } label: {
                Label("Open in chat", systemImage: "paperplane")
            }
            .buttonStyle(.plain)
            .foregroundStyle(PidgyDashboardTheme.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(DashboardCapsuleBackground())
        }
        .task(id: item?.chat.id) {
            await loadConversationContext()
        }
    }

    private func loadConversationContext() async {
        guard let chatId = item?.chat.id else {
            conversationContext = []
            return
        }
        isLoadingContext = true
        defer { isLoadingContext = false }
        let recent = await DatabaseManager.shared.loadMessages(
            chatId: chatId,
            limit: Self.maxEvidenceRows + 2
        )
        conversationContext = recent.sorted { $0.date < $1.date }
    }

    /// Treats the FollowUpItem's `lastMessage` as the "source" — it's the
    /// message that drove the categorization. Surrounding chat history is
    /// loaded from the DB and rendered as context. Falls back to a one-row
    /// list with just the last message if the DB hasn't cached the chat yet.
    private func mergedEvidenceItems(for item: FollowUpItem) -> [EvidenceContextItem] {
        let sourceId = item.lastMessage.id
        let context = conversationContext
            .filter { $0.id != sourceId }
            .suffix(Self.maxEvidenceRows - 1)
            .map { record in
                EvidenceContextItem(
                    id: record.id,
                    date: record.date,
                    senderName: senderLabel(for: record),
                    isOutgoing: record.isOutgoing,
                    text: nonEmptyDisplayText(for: record),
                    isSource: false
                )
            }

        let source = EvidenceContextItem(
            id: sourceId,
            date: item.lastMessage.date,
            senderName: item.lastMessage.senderName ?? "Unknown",
            isOutgoing: item.lastMessage.isOutgoing,
            text: item.lastMessage.displayText,
            isSource: true
        )

        return (context + [source]).sorted { $0.date < $1.date }
    }

    private func senderLabel(for record: DatabaseManager.MessageRecord) -> String {
        if record.isOutgoing { return "You" }
        let trimmed = record.senderName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Unknown" : trimmed
    }

    private func nonEmptyDisplayText(for record: DatabaseManager.MessageRecord) -> String {
        let trimmed = record.textContent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        if let media = record.mediaTypeRaw, !media.isEmpty {
            return "[\(media)]"
        }
        return "[empty]"
    }

    private func evidenceTrailing(for items: [EvidenceContextItem]) -> String {
        if items.isEmpty { return isLoadingContext ? "loading…" : "no context" }
        let contextCount = items.count - items.filter(\.isSource).count
        if contextCount == 0 { return "1 source" }
        return "1 source · \(contextCount) context"
    }
}

struct DashboardFeedRow: View {
    @EnvironmentObject private var telegramService: TelegramService

    let item: DashboardFeedItem

    var body: some View {
        HStack(spacing: 12) {
            DashboardTelegramAvatar(
                chat: chat,
                fallbackTitle: item.avatarLabel,
                size: PidgyDashboardTheme.rowAvatarSize
            )

            // Title at regular weight (design spec: fontSize 14, no
            // explicit weight → 400 regular). Metadata collapsed onto a
            // single fg-3 line: "<person> · <chat-or-type> [· <topic>]".
            // The old two-line treatment doubled the visual mass of every
            // row; the design's compact context line is what gives the
            // feed its calmer rhythm.
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(Font.Pidgy.body)
                    .foregroundStyle(PidgyDashboardTheme.primary)
                    .lineLimit(1)

                Text(contextLine)
                    .font(PidgyDashboardTheme.metadataFont)
                    .foregroundStyle(PidgyDashboardTheme.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 14)

            Text(DateFormatting.compactRelativeTime(from: item.date))
                .font(PidgyDashboardTheme.monoTimestampFont)
                .foregroundStyle(item.section == .onFire ? PidgyDashboardTheme.brand : PidgyDashboardTheme.tertiary)
                .frame(width: PidgyDashboardTheme.timestampColumnWidth, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: PidgyDashboardTheme.rowHeight)
        .contentShape(Rectangle())
    }

    private var contextLine: String {
        var parts: [String] = [item.person, item.chat]
        if let topic = item.topic, !topic.isEmpty {
            parts.append(topic)
        }
        return parts.joined(separator: " · ")
    }

    private var chat: TGChat? {
        switch item.kind {
        case .reply(let reply):
            return reply.chat
        case .task(let task):
            return telegramService.visibleChats.first { $0.id == task.chatId }
                ?? telegramService.chats.first { $0.id == task.chatId }
        }
    }
}

struct DashboardAttentionRow: View {
    let item: FollowUpItem
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            DashboardTelegramAvatar(
                chat: item.chat,
                fallbackTitle: personName,
                size: PidgyDashboardTheme.rowAvatarSize
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(personName)
                        .font(PidgyDashboardTheme.rowEmphasisFont)
                        .foregroundStyle(PidgyDashboardTheme.primary)
                        .lineLimit(1)
                    Text("·")
                        .foregroundStyle(PidgyDashboardTheme.tertiary)
                    Text(item.chat.title)
                        .font(PidgyDashboardTheme.detailBodyFont)
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                        .lineLimit(1)
                    Text("· \(item.chat.chatType.displayName)")
                        .font(PidgyDashboardTheme.detailBodyFont)
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                        .lineLimit(1)
                }

                Text(item.suggestedAction ?? item.lastMessage.displayText)
                    .font(PidgyDashboardTheme.detailBodyFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Text(DateFormatting.compactRelativeTime(from: item.lastMessage.date))
                .font(PidgyDashboardTheme.monoTimestampFont)
                .foregroundStyle(item.category == .onMe ? PidgyDashboardTheme.brand : PidgyDashboardTheme.secondary)
                .frame(width: PidgyDashboardTheme.timestampColumnWidth, alignment: .trailing)
        }
        .padding(.horizontal, PidgyDashboardTheme.rowHorizontalPadding)
        .frame(height: 58)
        .background(
            RoundedRectangle(cornerRadius: PidgyDashboardTheme.selectedRowCornerRadius, style: .continuous)
                .fill(isSelected ? Color.Pidgy.bg4 : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private var personName: String {
        item.chat.chatType.isPrivate ? item.chat.title : (item.lastMessage.senderName ?? item.chat.title)
    }
}

enum DashboardFeedSection: String, CaseIterable, Identifiable {
    case onFire
    case thisWeek
    case later

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onFire:
            return "On fire"
        case .thisWeek:
            return "This week"
        case .later:
            return "Later"
        }
    }

    var rank: Int {
        switch self {
        case .onFire:
            return 0
        case .thisWeek:
            return 1
        case .later:
            return 2
        }
    }
}

enum DashboardFeedKind {
    case task(DashboardTask)
    case reply(FollowUpItem)
}

struct DashboardFeedItem: Identifiable {
    let id: String
    let title: String
    let person: String
    let chat: String
    let topic: String?
    let avatarLabel: String
    let date: Date
    let section: DashboardFeedSection
    let kind: DashboardFeedKind

    static func task(_ task: DashboardTask) -> DashboardFeedItem {
        DashboardFeedItem(
            id: "task-\(task.id)",
            title: task.title,
            person: task.personName.isEmpty ? task.ownerName : task.personName,
            chat: task.chatTitle,
            topic: task.topicName ?? "Uncategorized",
            avatarLabel: task.personName.isEmpty ? task.chatTitle : task.personName,
            date: task.latestSourceDate ?? task.updatedAt,
            section: section(for: task.priority),
            kind: .task(task)
        )
    }

    static func reply(_ item: FollowUpItem) -> DashboardFeedItem {
        let isPrivate = item.chat.chatType.isPrivate
        let person = isPrivate ? item.chat.title : item.lastMessage.senderName ?? item.chat.title
        // For DMs the person column already names the contact, so the
        // chat slot shows the type tag ("DM") for context. For groups /
        // supergroups / channels, show the actual chat title — the
        // generic "Group" / "Supergroup" word was uninformative when
        // multiple group chats stacked in the feed.
        let chatLabel = isPrivate ? item.chat.chatType.displayName : item.chat.title
        return DashboardFeedItem(
            id: "reply-\(item.chat.id)",
            title: item.suggestedAction ?? item.lastMessage.displayText,
            person: person,
            chat: chatLabel,
            topic: nil,
            avatarLabel: person,
            date: item.lastMessage.date,
            section: section(for: item.category),
            kind: .reply(item)
        )
    }

    private static func section(for priority: DashboardTaskPriority) -> DashboardFeedSection {
        switch priority {
        case .high:
            return .onFire
        case .medium:
            return .thisWeek
        case .low:
            return .later
        }
    }

    private static func section(for category: FollowUpItem.Category) -> DashboardFeedSection {
        switch category {
        case .onMe:
            return .onFire
        case .onThem:
            return .thisWeek
        case .quiet:
            return .later
        }
    }
}
