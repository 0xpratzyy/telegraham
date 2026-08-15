import SwiftUI

struct DashboardTaskRow: View {
    @EnvironmentObject private var sourceRegistry: SourceRegistry

    let task: DashboardTask
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            taskAvatar

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(displayPerson)
                        .font(PidgyDashboardTheme.rowTitleFont)
                        .foregroundStyle(task.status == .done ? PidgyDashboardTheme.secondary : PidgyDashboardTheme.primary)
                        .lineLimit(1)
                        .layoutPriority(1)

                    DashboardInlineSourceLabel(source: sourceKind)
                }

                Text(task.title)
                    .font(PidgyDashboardTheme.metadataFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                    .lineLimit(1)
                    .strikethrough(task.status == .done)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 4) {
                Text(DateFormatting.dashboardListTimestamp(from: task.latestSourceDate ?? task.updatedAt))
                    .font(PidgyDashboardTheme.monoTimestampFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)

                if task.status != .open {
                    Text(task.status.label)
                        .font(PidgyDashboardTheme.captionFont)
                        .foregroundStyle(PidgyDashboardTheme.tertiary)
                }
            }
            .frame(width: PidgyDashboardTheme.timestampColumnWidth, alignment: .trailing)
        }
        .padding(.horizontal, PidgyDashboardTheme.rowHorizontalPadding)
        .frame(height: 58)
        .pidgyRow(isSelected: isSelected)
    }

    private var chat: TGChat? {
        sourceRegistry.chat(id: task.chatId)
    }

    private var sourceKind: MessageSourceKind {
        chat?.source.kind ?? .telegram
    }

    @ViewBuilder
    private var taskAvatar: some View {
        DashboardIdentityAvatar(
            chat: chat,
            label: avatarLabel,
            source: sourceKind,
            userID: identityUserID,
            size: PidgyDashboardTheme.rowAvatarSize
        )
    }

    private var avatarLabel: String {
        task.personName.isEmpty ? task.chatTitle : task.personName
    }

    /// A task can come from a channel while its identity is a person. Only use
    /// the chat's latest sender photo when it is demonstrably that same person;
    /// otherwise stable initials are more honest than the channel avatar.
    private var identityUserID: Int64? {
        guard let message = chat?.lastMessage,
              DashboardTaskPresentation.sameIdentity(message.senderName, avatarLabel)
        else { return nil }
        return message.senderUserId
    }

    private var displayPerson: String {
        DashboardTaskPresentation.displayPerson(task: task, source: sourceKind)
    }
}

enum DashboardTaskPresentation {
    /// Builds a short, source-aware metadata line while removing repetitions
    /// like "Tushar Pasi · Tushar Pasi" and title/subject duplication.
    static func metadataLine(task: DashboardTask, source: MessageSourceKind) -> String {
        var parts: [String] = []
        appendUnique(displayPerson(task: task, source: source), to: &parts)

        if !sameText(task.chatTitle, task.title) {
            appendUnique(task.chatTitle, to: &parts)
        }

        return parts.joined(separator: "  ·  ")
    }

    static func sameIdentity(_ lhs: String?, _ rhs: String) -> Bool {
        guard let lhs else { return false }
        return normalize(lhs) == normalize(rhs)
    }

    /// Tasks deliberately keep their canonical source evidence for auditing,
    /// but the inspector is an action surface rather than an email/chat reader.
    /// Summarize provenance without repeating the title or leaking raw HTML.
    static func detailSummary(task: DashboardTask, source: MessageSourceKind, conversationTitle: String? = nil) -> String {
        let person = displayPerson(task: task, source: source)
        let context = (conversationTitle ?? task.chatTitle).trimmingCharacters(in: .whitespacesAndNewlines)

        let origin: String
        if !context.isEmpty, !sameText(context, task.title) {
            origin = " about \u{201c}\(context)\u{201d}"
        } else {
            origin = ""
        }

        switch source {
        case .gmail:
            return "\(person.isEmpty ? "This sender" : person) sent an email\(origin). Pidgy identified \u{201c}\(task.title)\u{201d} as the action you need to take. Open Gmail for the original details."
        case .slack:
            return "\(person.isEmpty ? "This person" : person) raised this in Slack\(origin). Open Slack for the surrounding conversation."
        case .telegram:
            return "\(person.isEmpty ? "This person" : person) raised this in Telegram\(origin). Open Telegram for the surrounding conversation."
        case .whatsapp:
            return "\(person.isEmpty ? "This person" : person) raised this in WhatsApp\(origin). Open the source for the surrounding conversation."
        }
    }

    static func displayPerson(task: DashboardTask, source: MessageSourceKind) -> String {
        let raw = (task.personName.isEmpty ? task.ownerName : task.personName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard source == .gmail else { return raw }

        let sender = GmailPresentation.senderName(from: raw, fallback: "Email sender")
        let separated = sender
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return separated == separated.lowercased() ? separated.capitalized : separated
    }

    private static func appendUnique(_ value: String, to parts: inout [String]) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !parts.contains(where: { sameText($0, trimmed) })
        else { return }
        parts.append(trimmed)
    }

    private static func sameText(_ lhs: String, _ rhs: String) -> Bool {
        normalize(lhs) == normalize(rhs)
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct DashboardPersonRow: View {
    @EnvironmentObject private var sourceRegistry: SourceRegistry

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
                Text(contact.lastInteractionAt.map(Self.lastActiveLabel) ?? contact.category)
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
        .pidgyRow(isSelected: isSelected)
    }

    private var privateChat: TGChat? {
        sourceRegistry.privateChat(userId: contact.entityId)
    }

    /// "active now" / "last active 2d ago" for recent dates; beyond a week
    /// compactRelativeTime returns an ABSOLUTE date ("Apr 9"), where the old
    /// "last Apr 9 ago" phrasing read broken.
    private static func lastActiveLabel(_ date: Date) -> String {
        let stamp = DateFormatting.compactRelativeTime(from: date)
        if stamp == "now" { return "active now" }
        return stamp.first?.isNumber == true && !stamp.contains(" ")
            ? "last active \(stamp) ago"
            : "last active \(stamp)"
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
    case onMe
    case onThem
    case quiet

    var id: String { rawValue }

    var label: String {
        switch self {
        case .onMe:
            return "On me"
        case .onThem:
            return "On them"
        case .quiet:
            return "Quiet"
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
