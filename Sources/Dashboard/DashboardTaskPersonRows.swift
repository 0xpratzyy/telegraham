import SwiftUI

struct DashboardTaskRow: View {
    @EnvironmentObject private var telegramService: TelegramService

    let task: DashboardTask
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            DashboardTelegramAvatar(
                chat: chat,
                fallbackTitle: avatarLabel,
                size: PidgyDashboardTheme.rowAvatarSize
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(PidgyDashboardTheme.rowTitleFont)
                    .foregroundStyle(task.status == .done ? PidgyDashboardTheme.secondary : PidgyDashboardTheme.primary)
                    .lineLimit(1)
                    .strikethrough(task.status == .done)

                HStack(spacing: 7) {
                    Text(displayPerson)
                        .font(PidgyDashboardTheme.metadataMediumFont)
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                        .lineLimit(1)
                    Text("· \(task.chatTitle)")
                        .font(PidgyDashboardTheme.metadataFont)
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            Text(DateFormatting.dashboardListTimestamp(from: task.latestSourceDate ?? task.updatedAt))
                .font(PidgyDashboardTheme.monoTimestampFont)
                .foregroundStyle(PidgyDashboardTheme.secondary)
                .frame(width: PidgyDashboardTheme.timestampColumnWidth, alignment: .trailing)
        }
        .padding(.horizontal, PidgyDashboardTheme.rowHorizontalPadding)
        .frame(height: PidgyDashboardTheme.compactRowHeight)
        .background(
            RoundedRectangle(cornerRadius: PidgyDashboardTheme.selectedRowCornerRadius, style: .continuous)
                .fill(isSelected ? Color.Pidgy.bg4 : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private var chat: TGChat? {
        telegramService.visibleChats.first { $0.id == task.chatId }
            ?? telegramService.chats.first { $0.id == task.chatId }
    }

    private var avatarLabel: String {
        task.personName.isEmpty ? task.chatTitle : task.personName
    }

    private var displayPerson: String {
        task.personName.isEmpty ? task.ownerName : task.personName
    }
}

struct DashboardPersonRow: View {
    @EnvironmentObject private var telegramService: TelegramService

    let signal: DashboardPersonSignal
    let isSelected: Bool

    private var contact: RelationGraph.Node { signal.contact }

    var body: some View {
        HStack(spacing: 12) {
            DashboardTelegramAvatar(
                chat: privateChat,
                fallbackTitle: contact.bestDisplayName,
                size: PidgyDashboardTheme.rowAvatarSize
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(contact.bestDisplayName)
                    .font(PidgyDashboardTheme.rowEmphasisFont)
                    .foregroundStyle(PidgyDashboardTheme.primary)
                    .lineLimit(1)
                Text(contact.lastInteractionAt.map { "last \(DateFormatting.compactRelativeTime(from: $0)) ago" } ?? contact.category)
                    .font(PidgyDashboardTheme.metadataFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if signal.openReplyCount > 0 {
                HStack(spacing: 5) {
                    DashboardPriorityDot(color: PidgyDashboardTheme.blue)
                    Text("\(signal.openReplyCount) \(signal.openReplyCount == 1 ? "reply" : "replies")")
                }
                .font(PidgyDashboardTheme.monoCaptionFont)
                .foregroundStyle(PidgyDashboardTheme.blue)
            } else if signal.openTaskCount > 0 {
                HStack(spacing: 5) {
                    DashboardPriorityDot(color: PidgyDashboardTheme.brand)
                    Text("\(signal.openTaskCount) \(signal.openTaskCount == 1 ? "task" : "tasks")")
                }
                .font(PidgyDashboardTheme.monoCaptionFont)
                .foregroundStyle(PidgyDashboardTheme.brand)
            } else {
                Text("\(Int(contact.interactionScore.rounded()))")
                    .font(PidgyDashboardTheme.monoCaptionFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
            }
        }
        .padding(.horizontal, PidgyDashboardTheme.rowHorizontalPadding)
        .frame(height: PidgyDashboardTheme.compactRowHeight)
        .background(
            RoundedRectangle(cornerRadius: PidgyDashboardTheme.selectedRowCornerRadius, style: .continuous)
                .fill(isSelected ? Color.Pidgy.bg4 : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private var privateChat: TGChat? {
        let allChats = telegramService.visibleChats + telegramService.chats
        return allChats.first { chat in
            guard case .privateChat(let userId) = chat.chatType else { return false }
            return userId == contact.entityId
        }
    }
}

struct DashboardMiniTaskRow: View {
    let task: DashboardTask

    var body: some View {
        HStack(spacing: 10) {
            DashboardPriorityDot(priority: task.priority)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(PidgyDashboardTheme.detailBodyFont)
                    .foregroundStyle(PidgyDashboardTheme.primary)
                    .lineLimit(1)
                Text(task.status.label)
                    .font(PidgyDashboardTheme.captionFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
            }
            Spacer()
            Text(task.latestSourceDate.map(DateFormatting.compactRelativeTime(from:)) ?? "-")
                .font(PidgyDashboardTheme.monoCaptionFont)
                .foregroundStyle(PidgyDashboardTheme.secondary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

struct DashboardMiniReplyRow: View {
    let item: FollowUpItem

    var body: some View {
        HStack(spacing: 10) {
            DashboardPriorityDot(color: categoryTint(item.category))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.suggestedAction ?? item.lastMessage.displayText)
                    .font(PidgyDashboardTheme.detailBodyFont)
                    .foregroundStyle(PidgyDashboardTheme.primary)
                    .lineLimit(1)
                Text(item.chat.title)
                    .font(PidgyDashboardTheme.captionFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(DateFormatting.compactRelativeTime(from: item.lastMessage.date))
                .font(PidgyDashboardTheme.monoCaptionFont)
                .foregroundStyle(PidgyDashboardTheme.secondary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

enum DashboardReplyFilter: String, CaseIterable, Identifiable {
    case needsYou
    case allOpen
    case muted

    var id: String { rawValue }

    var label: String {
        switch self {
        case .needsYou:
            return "Needs you"
        case .allOpen:
            return "All open"
        case .muted:
            return "Muted"
        }
    }
}

enum DashboardStatusFilter: String, CaseIterable, Identifiable {
    case open
    case snoozed
    case done
    case ignored
    case all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all:
            return "All"
        case .open:
            return "Open"
        case .snoozed:
            return "Snoozed"
        case .done:
            return "Done"
        case .ignored:
            return "Ignored"
        }
    }

    var status: DashboardTaskStatus? {
        switch self {
        case .all:
            return nil
        case .open:
            return .open
        case .snoozed:
            return .snoozed
        case .done:
            return .done
        case .ignored:
            return .ignored
        }
    }
}

struct DashboardChatOption: Identifiable {
    let chatId: Int64
    let title: String

    var id: Int64 { chatId }
}

func topicTint(for task: DashboardTask) -> Color {
    if let topicId = task.topicId {
        return PidgyDashboardTheme.topicTint(topicId)
    }
    return PidgyDashboardTheme.secondary
}

func priorityColor(_ priority: DashboardTaskPriority) -> Color {
    switch priority {
    case .high:
        return PidgyDashboardTheme.red
    case .medium:
        return PidgyDashboardTheme.yellow
    case .low:
        return PidgyDashboardTheme.secondary
    }
}
