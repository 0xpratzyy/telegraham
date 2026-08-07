import AppKit
import SwiftUI

struct DashboardTaskDetail: View {
    @EnvironmentObject private var telegramService: TelegramService
    @EnvironmentObject private var sourceRegistry: SourceRegistry
    @ObservedObject private var chatOpenState = ChatOpenState.shared
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
                taskHeader(task)
                taskStatus(task)
                nextStep(task)
                taskEvidence(task)
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
            if let task {
                taskActions(task)
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

    @ViewBuilder
    private func taskHeader(_ task: DashboardTask) -> some View {
        let source = sourceKind(for: task)
        let age = DateFormatting.compactRelativeTime(from: task.latestSourceDate ?? task.updatedAt)

        DashboardDetailCover {
            HStack(alignment: .top, spacing: 10) {
                DashboardIdentityAvatar(
                    chat: sourceRegistry.chat(id: task.chatId),
                    label: avatarLabel(for: task),
                    source: source,
                    userID: identityUserID(for: task),
                    size: 40
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(displayPerson(for: task))
                        .font(PidgyDashboardTheme.metadataMediumFont)
                        .foregroundStyle(PidgyDashboardTheme.primary)
                        .lineLimit(1)
                    Text("\(source.displayName)  ·  \(age)")
                        .font(PidgyDashboardTheme.metadataFont)
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                }

                Spacer(minLength: 8)

                DashboardTopicChip(
                    text: task.topicName ?? task.status.label,
                    tint: topicTint(for: task)
                )
                .padding(.trailing, 22)
            }

            Text(task.title)
                .font(PidgyDashboardTheme.taskDetailTitleFont)
                .tracking(-0.4)
                .foregroundStyle(PidgyDashboardTheme.primary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 7) {
                DashboardPriorityDot(priority: task.priority)
                Text("\(task.priority.label) priority")
                    .font(PidgyDashboardTheme.metadataMediumFont)

                if let dueAt = task.dueAt {
                    Text("·")
                    Label(
                        "Due \(DateFormatting.dashboardListTimestamp(from: dueAt))",
                        systemImage: "calendar"
                    )
                }
            }
            .font(PidgyDashboardTheme.metadataFont)
            .foregroundStyle(PidgyDashboardTheme.secondary)
        }
    }

    @ViewBuilder
    private func taskStatus(_ task: DashboardTask) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: statusIcon(for: task))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(statusTint(for: task))
                .frame(width: 28, height: 28)
                .background(statusTint(for: task).opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle(for: task))
                    .font(PidgyDashboardTheme.metadataMediumFont)
                    .foregroundStyle(PidgyDashboardTheme.primary)
                Text(statusSubtitle(for: task))
                    .font(PidgyDashboardTheme.metadataFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .overlay(alignment: .bottom) { detailDivider }
    }

    @ViewBuilder
    private func nextStep(_ task: DashboardTask) -> some View {
        DashboardDetailSection(
            title: "Next step",
            trailing: "AI \(Int((task.confidence * 100).rounded()))%"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text(task.suggestedAction.isEmpty ? fallbackAction(for: task) : task.suggestedAction)
                    .font(PidgyDashboardTheme.detailBodyFont.weight(.medium))
                    .foregroundStyle(PidgyDashboardTheme.primary)
                    .lineSpacing(3)

                if !task.summary.isEmpty,
                   task.summary.localizedCaseInsensitiveCompare(task.suggestedAction) != .orderedSame {
                    Text(task.summary)
                        .font(PidgyDashboardTheme.detailBodyFont)
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                        .lineSpacing(3)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PidgyDashboardTheme.paper)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(PidgyDashboardTheme.rule)
            )
        }
    }

    @ViewBuilder
    private func taskEvidence(_ task: DashboardTask) -> some View {
        let merged = mergedEvidenceItems()
        let source = sourceKind(for: task)

        DashboardDetailSection(
            title: "Source context",
            trailing: evidenceTrailing(for: merged)
        ) {
            VStack(spacing: 8) {
                if merged.isEmpty {
                    Text(isLoadingContext
                         ? "Loading nearby messages…"
                         : "No source context was stored for this task.")
                        .font(PidgyDashboardTheme.detailBodyFont)
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(merged) { item in
                        Button {
                            openEvidence(item, for: task)
                        } label: {
                            DashboardTaskEvidenceCard(
                                item: item,
                                text: evidenceText(item, task: task, source: source),
                                sourceName: source.displayName
                            )
                        }
                        .buttonStyle(.pidgyPress)
                        .help("Open in \(source.displayName)")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func taskActions(_ task: DashboardTask) -> some View {
        let source = sourceKind(for: task)
        HStack(spacing: 8) {
            Button {
                onUpdateStatus(task, task.isClosed ? .open : .done, nil)
            } label: {
                Label(
                    task.isClosed ? "Re-open" : "Mark done",
                    systemImage: task.isClosed ? "arrow.uturn.backward" : "checkmark"
                )
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(PidgyDashboardTheme.primary)
            .pidgyCapsuleBackground()

            Button {
                if chatOpenState.openingChatId == nil { onOpenChat(task.chatId) }
            } label: {
                Group {
                    if chatOpenState.openingChatId == task.chatId {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Open", systemImage: source.systemImage)
                    }
                }
                .frame(minWidth: 68)
                .frame(height: 36)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(PidgyDashboardTheme.primary)
            .pidgyCapsuleBackground()
            .disabled(chatOpenState.openingChatId == task.chatId)
            .help("Open in \(source.displayName)")

            Menu {
                if !task.isClosed {
                    Button("Snooze until tomorrow", systemImage: "moon.zzz") {
                        onUpdateStatus(task, .snoozed, Date().addingTimeInterval(86_400))
                    }
                    Button("Snooze for one week", systemImage: "calendar.badge.clock") {
                        onUpdateStatus(task, .snoozed, Date().addingTimeInterval(604_800))
                    }
                    if task.status == .snoozed {
                        Button("Move back to Open", systemImage: "tray") {
                            onUpdateStatus(task, .open, nil)
                        }
                    }
                    Divider()
                    Button("Ignore task", systemImage: "eye.slash", role: .destructive) {
                        onUpdateStatus(task, .ignored, nil)
                    }
                    Divider()
                }
                Button("Copy task", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(task.title, forType: .string)
                }
                Button("Flag extraction…", systemImage: "flag") {
                    FlaggedAnswerFixture
                        .task(task, evidence: evidence)
                        .submitToFeedbackSheet()
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 36, height: 36)
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(PidgyDashboardTheme.secondary)
            .pidgyCapsuleBackground()
            .help("More task actions")
        }
    }

    private var detailDivider: some View {
        Rectangle()
            .fill(PidgyDashboardTheme.rule)
            .frame(height: 1)
    }

    private func sourceKind(for task: DashboardTask) -> MessageSourceKind {
        sourceRegistry.chat(id: task.chatId)?.source.kind ?? .telegram
    }

    private func avatarLabel(for task: DashboardTask) -> String {
        let person = displayPerson(for: task).trimmingCharacters(in: .whitespacesAndNewlines)
        if !person.isEmpty { return person }
        if let sender = evidence.first?.senderName, !sender.isEmpty { return sender }
        return task.chatTitle
    }

    private func identityUserID(for task: DashboardTask) -> Int64? {
        guard let chat = sourceRegistry.chat(id: task.chatId),
              let message = chat.lastMessage,
              DashboardTaskPresentation.sameIdentity(message.senderName, avatarLabel(for: task))
        else { return nil }
        return message.senderUserId
    }

    private func fallbackAction(for task: DashboardTask) -> String {
        "Review the source context and complete \(task.title.lowercased())."
    }

    private func statusTitle(for task: DashboardTask) -> String {
        switch task.status {
        case .open: return "Ready to act"
        case .done: return "Task completed"
        case .snoozed: return "Snoozed"
        case .ignored: return "Task ignored"
        }
    }

    private func statusSubtitle(for task: DashboardTask) -> String {
        switch task.status {
        case .open:
            if let dueAt = task.dueAt {
                return "Due \(DateFormatting.dashboardListTimestamp(from: dueAt))."
            }
            return "Pidgy found a concrete action for you."
        case .done:
            return "This task is out of your active queue."
        case .snoozed:
            if let until = task.snoozedUntil {
                return "Returns \(DateFormatting.compactRelativeTime(from: until))."
            }
            return "Hidden until its reminder becomes active."
        case .ignored:
            return "This item will stay out of your active queue."
        }
    }

    private func statusIcon(for task: DashboardTask) -> String {
        switch task.status {
        case .open: return "bolt.fill"
        case .done: return "checkmark"
        case .snoozed: return "moon.zzz.fill"
        case .ignored: return "eye.slash.fill"
        }
    }

    private func statusTint(for task: DashboardTask) -> Color {
        switch task.status {
        case .open: return Color.Pidgy.warning
        case .done: return Color.Pidgy.success
        case .snoozed: return Color.Pidgy.accent
        case .ignored: return PidgyDashboardTheme.secondary
        }
    }

    private func evidenceText(
        _ item: EvidenceContextItem,
        task: DashboardTask,
        source: MessageSourceKind
    ) -> String {
        guard source == .gmail else { return item.text }
        return GmailPresentation.compactBody(
            subject: task.chatTitle,
            messageText: item.text,
            maxCharacters: item.isSource ? 650 : 320
        )
    }

    private func openEvidence(_ item: EvidenceContextItem, for task: DashboardTask) {
        if sourceKind(for: task) == .telegram {
            Task {
                await telegramService.openMessageInTelegram(
                    chatId: task.chatId,
                    messageId: item.id
                )
            }
        } else {
            onOpenChat(task.chatId)
        }
    }

    private func loadConversationContext() async {
        guard let chatId = task?.chatId else {
            conversationContext = []
            return
        }
        isLoadingContext = true
        defer { isLoadingContext = false }
        // Anchor context on the SOURCE message so the user sees the conversation
        // AROUND where the loop was created — not the chat's latest, unrelated
        // chatter. Fall back to recent messages only if there's no source id.
        let anchor = evidence.map(\.messageId).max() ?? 0
        let nearby: [DatabaseManager.MessageRecord]
        if anchor > 0 {
            nearby = await DatabaseManager.shared.loadMessagesAround(
                chatId: chatId,
                messageId: anchor,
                window: Self.maxEvidenceRows
            )
        } else {
            nearby = await DatabaseManager.shared.loadMessages(
                chatId: chatId,
                limit: Self.maxEvidenceRows + 4
            )
        }
        conversationContext = nearby.sorted { $0.date < $1.date }
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

/// A bounded, readable source preview for the task inspector. Canonical
/// evidence remains untouched in storage; this view only reduces transport
/// noise and prevents one long email/message from swallowing the panel.
struct DashboardTaskEvidenceCard: View {
    let item: EvidenceContextItem
    let text: String
    let sourceName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Text(item.senderName)
                    .font(PidgyDashboardTheme.metadataMediumFont)
                    .foregroundStyle(item.isOutgoing
                        ? PidgyDashboardTheme.brand
                        : PidgyDashboardTheme.primary)
                    .lineLimit(1)

                Text("·")
                    .foregroundStyle(PidgyDashboardTheme.tertiary)

                Text(DateFormatting.compactRelativeTime(from: item.date))
                    .font(PidgyDashboardTheme.monoCaptionFont)
                    .foregroundStyle(PidgyDashboardTheme.tertiary)

                Spacer(minLength: 6)

                if item.isSource {
                    Label(sourceName, systemImage: "arrow.up.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(PidgyDashboardTheme.brand)
                }
            }

            Text(text)
                .font(PidgyDashboardTheme.detailBodyFont)
                .foregroundStyle(item.isSource
                    ? PidgyDashboardTheme.primary
                    : PidgyDashboardTheme.secondary)
                .lineSpacing(3)
                .lineLimit(item.isSource ? 9 : 4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(item.isSource
                    ? PidgyDashboardTheme.paper
                    : PidgyDashboardTheme.paper.opacity(0.48))
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(item.isSource ? PidgyDashboardTheme.brand : Color.Pidgy.border2)
                .frame(width: 3)
                .padding(.vertical, 8)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(PidgyDashboardTheme.rule)
        )
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
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
    @EnvironmentObject private var sourceRegistry: SourceRegistry
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
    @State private var personFacts: [Fact] = []   // context-layer (#48)

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

                // Context layer (#48): durable facts about this person, from the
                // one fact store. (Open loops are already in the columns below.)
                if ContextLayer.enabled, !durableFacts.isEmpty {
                    DashboardPersonFactsSection(facts: durableFacts)
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
                .pidgyCapsuleBackground()
            }
        }
        .foregroundStyle(PidgyDashboardTheme.primary)
        .task(id: contact?.entityId) {
            await loadRecentMessages(for: contact)
            await loadAIProfile(for: contact)
            await loadPersonFacts(for: contact)
        }
    }

    private func loadPersonFacts(for contact: RelationGraph.Node?) async {
        guard ContextLayer.enabled, let contact, contact.entityId != 0 else {
            personFacts = []
            return
        }
        personFacts = await DatabaseManager.shared.loadFactsForPerson(personId: contact.entityId)
    }

    private var durableFacts: [Fact] {
        personFacts.filter { !$0.predicate.isOpenLoop }
    }

    private func loadAIProfile(for contact: RelationGraph.Node?) async {
        guard let contact, aiService.isConfigured else { return }
        let myUserId = telegramService.currentUser?.id ?? 0
        let chatTitleResolver: (Int64) -> String = { chatId in
            sourceRegistry.chat(id: chatId)?.title ?? ""
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
        sourceRegistry.privateChat(userId: contact.entityId)
    }

    private var allChats: [TGChat] {
        let allChats = sourceRegistry.visibleChats + sourceRegistry.chats
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

struct DashboardPersonFactsSection: View {
    let facts: [Fact]

    var body: some View {
        DashboardDetailSection(title: "What we know") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(facts) { fact in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Self.verb(fact.predicate))
                            .font(PidgyDashboardTheme.metadataFont)
                            .foregroundStyle(PidgyDashboardTheme.secondary)
                            .frame(width: 64, alignment: .leading)
                        Text(fact.objectText)
                            .font(PidgyDashboardTheme.metadataMediumFont)
                            .foregroundStyle(PidgyDashboardTheme.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private static func verb(_ p: FactPredicate) -> String {
        switch p {
        case .worksAt: return "works at"
        case .prefers: return "prefers"
        case .writesIn: return "writes in"
        default: return "note"
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
