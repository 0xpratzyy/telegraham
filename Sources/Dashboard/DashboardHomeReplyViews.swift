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
                return $0.date > $1.date
            }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("What to do now")
                        .font(PidgyDashboardTheme.pageTitleFont)
                        .foregroundStyle(PidgyDashboardTheme.primary)
                    Text("\(feedItems.count) active item\(feedItems.count == 1 ? "" : "s")")
                        .font(PidgyDashboardTheme.pageSubtitleFont)
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                }
                .padding(.horizontal, PidgyDashboardTheme.rowHorizontalPadding)
                .padding(.bottom, PidgyDashboardTheme.headerBottomPadding)

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
                    ForEach(DashboardFeedSection.allCases) { section in
                        let items = feedItems.filter { $0.section == section }
                        if !items.isEmpty {
                            DashboardSectionLabel(section.title)
                                .padding(.horizontal, PidgyDashboardTheme.rowHorizontalPadding)
                                .padding(.top, section == .onFire ? 0 : 2)
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
    let onRefresh: () -> Void
    let onOpenChat: (TGChat) -> Void

    @State private var filter: DashboardReplyFilter = .needsYou

    private var filteredItems: [FollowUpItem] {
        switch filter {
        case .needsYou:
            return items.filter { $0.category == .onMe }
        case .allOpen:
            return items
        case .muted:
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
                    onRefresh: onRefresh,
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
                needsCount: items.filter { $0.category == .onMe }.count,
                allCount: items.count,
                mutedCount: items.filter { $0.category == .quiet }.count
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
    let onRefresh: () -> Void
    let onOpenChat: (TGChat) -> Void
    let onClose: () -> Void

    var body: some View {
        DashboardDetailPane(onClose: onClose) {
            if let item {
                DashboardDetailCover {
                    DashboardTopicChip(text: item.category.rawValue, tint: categoryTint(item.category))
                    Text(item.chat.title)
                        .font(PidgyDashboardTheme.titleFont)
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

                DashboardDetailSection(title: "Latest message") {
                    Text(item.lastMessage.displayText)
                        .font(PidgyDashboardTheme.detailBodyFont)
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                        .lineLimit(8)
                        .lineSpacing(3)
                }
            } else {
                DashboardEmptyState(
                    systemImage: "arrowshape.turn.up.left",
                    title: "Nothing selected",
                    subtitle: "Choose a conversation to inspect its latest context."
                )
            }
        } actions: {
            Button(action: onRefresh) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .foregroundStyle(PidgyDashboardTheme.primary)

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

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(PidgyDashboardTheme.rowTitleFont)
                    .foregroundStyle(PidgyDashboardTheme.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(item.person)
                        .font(PidgyDashboardTheme.metadataMediumFont)
                        .foregroundStyle(PidgyDashboardTheme.primary.opacity(0.78))
                        .lineLimit(1)
                    Text("·")
                        .foregroundStyle(PidgyDashboardTheme.tertiary)
                    Text(item.chat)
                        .font(PidgyDashboardTheme.metadataFont)
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                        .lineLimit(1)
                    if let topic = item.topic {
                        Text("·")
                            .foregroundStyle(PidgyDashboardTheme.tertiary)
                        Text(topic)
                            .font(PidgyDashboardTheme.metadataFont)
                            .foregroundStyle(PidgyDashboardTheme.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 14)

            Text(DateFormatting.compactRelativeTime(from: item.date))
                .font(PidgyDashboardTheme.monoTimestampFont)
                .foregroundStyle(item.section == .onFire ? PidgyDashboardTheme.brand : PidgyDashboardTheme.secondary)
                .frame(width: PidgyDashboardTheme.timestampColumnWidth, alignment: .trailing)
        }
        .padding(.horizontal, PidgyDashboardTheme.rowHorizontalPadding)
        .frame(height: PidgyDashboardTheme.rowHeight)
        .contentShape(Rectangle())
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
        let person = item.chat.chatType.isPrivate ? item.chat.title : item.lastMessage.senderName ?? item.chat.title
        return DashboardFeedItem(
            id: "reply-\(item.chat.id)",
            title: item.suggestedAction ?? item.lastMessage.displayText,
            person: person,
            chat: item.chat.chatType.displayName,
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
