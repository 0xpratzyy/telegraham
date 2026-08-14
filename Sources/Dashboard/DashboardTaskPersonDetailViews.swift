import AppKit
import SwiftUI
import WebKit

struct DashboardTaskDetail: View {
    @EnvironmentObject private var telegramService: TelegramService
    @EnvironmentObject private var aiService: AIService
    @EnvironmentObject private var sourceRegistry: SourceRegistry
    @ObservedObject private var chatOpenState = ChatOpenState.shared
    @ObservedObject private var gmailConnection = GmailConnectionManager.shared
    let task: DashboardTask?
    let evidence: [DashboardTaskSourceMessage]
    let isRefreshing: Bool
    let onUpdateStatus: (DashboardTask, DashboardTaskStatus, Date?) -> Void
    let onOpenChat: (Int64) -> Void
    let onClose: () -> Void

    @State private var generatedSummary = ""
    @State private var generatedSummaryTaskId: Int64?
    @State private var isLoadingSummary = false
    @State private var conversationEvidence: [EvidenceContextItem] = []
    @State private var evidenceHeader: DashboardEvidenceContextHeader?
    @State private var isLoadingEvidence = false
    @State private var isEmailPreviewPresented = false

    var body: some View {
        DashboardDetailPane(onClose: onClose) {
            if let task {
                taskHeader(task)
                taskSummary(task)
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
                    subtitle: "Choose a task to review and act on it."
                )
            }
        } actions: {
            if let task {
                taskActions(task)
            }
        }
        .foregroundStyle(PidgyDashboardTheme.primary)
        .task(id: task?.id) {
            await loadDetailedSummary()
            await loadTaskEvidence()
        }
        .sheet(isPresented: $isEmailPreviewPresented) {
            if let task, let target = gmailPreviewTarget(for: task) {
                GmailEmailPreviewSheet(
                    source: target.source,
                    sourceMessageID: target.messageID
                )
            }
        }
    }

    private func displayPerson(for task: DashboardTask) -> String {
        DashboardTaskPresentation.displayPerson(task: task, source: sourceKind(for: task))
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
                    Text(DashboardSourceMetadata.providerLine(source: source, age: age))
                        .font(PidgyDashboardTheme.metadataFont)
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                        .lineLimit(1)
                    if let account = DashboardSourceMetadata.accountLabel(
                        source: source,
                        account: sourceRegistry.chat(id: task.chatId)?.source.account ?? "",
                        connectedGmailAccountCount: gmailConnection.accounts.count
                    ) {
                        Text(account)
                            .font(PidgyDashboardTheme.metadataFont)
                            .foregroundStyle(PidgyDashboardTheme.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }

                Spacer(minLength: 8)
                .padding(.trailing, 22)
            }

            Text(task.title)
                .font(PidgyDashboardTheme.taskDetailTitleFont)
                .tracking(-0.4)
                .foregroundStyle(PidgyDashboardTheme.primary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if gmailPreviewTarget(for: task) != nil {
                    Button {
                        isEmailPreviewPresented = true
                    } label: {
                        Label("Preview email", systemImage: "doc.richtext")
                            .font(PidgyDashboardTheme.metadataMediumFont)
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PidgyDashboardTheme.primary)
                    .pidgyCapsuleBackground()
                    .fixedSize()
                    .help("Preview email in Pidgy")
                }

                sourceOpenButton(task, height: 30)
            }

            if let dueAt = task.dueAt {
                Label(
                    "Due \(DateFormatting.dashboardListTimestamp(from: dueAt))",
                    systemImage: "calendar"
                )
                .font(PidgyDashboardTheme.metadataFont)
                .foregroundStyle(PidgyDashboardTheme.secondary)
            }
        }
    }

    @ViewBuilder
    private func taskSummary(_ task: DashboardTask) -> some View {
        DashboardDetailSection(title: "Summary") {
            if shouldShowSummarySkeleton(for: task) {
                DashboardSkeletonTextBlock(lineCount: 4)
            } else {
                Text(displayedSummary(for: task))
                    .font(PidgyDashboardTheme.detailBodyFont)
                    .foregroundStyle(PidgyDashboardTheme.primary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func shouldShowSummarySkeleton(for task: DashboardTask) -> Bool {
        sourceKind(for: task) == .gmail
            && (generatedSummaryTaskId != task.id || isLoadingSummary)
    }

    private func displayedSummary(for task: DashboardTask) -> String {
        if generatedSummaryTaskId == task.id {
            let summary = generatedSummary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !summary.isEmpty { return summary }
        }
        return DashboardTaskPresentation.detailSummary(task: task, source: sourceKind(for: task))
    }

    @ViewBuilder
    private func taskEvidence(_ task: DashboardTask) -> some View {
        let source = sourceKind(for: task)
        if source == .slack || source == .telegram {
            if isLoadingEvidence && conversationEvidence.isEmpty {
                DashboardDetailSection(title: "Evidence") {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading conversation…")
                            .font(PidgyDashboardTheme.metadataFont)
                            .foregroundStyle(PidgyDashboardTheme.secondary)
                    }
                }
            } else if !conversationEvidence.isEmpty {
                let contextCount = conversationEvidence.filter { !$0.isSource }.count
                DashboardDetailSection(
                    title: "Evidence",
                    trailing: "1 source · \(contextCount) context"
                ) {
                    DashboardEvidenceConversationView(
                        items: conversationEvidence,
                        sourceMessageID: evidence.first?.messageId,
                        header: evidenceHeader
                    )
                }
            }
        }
    }

    @MainActor
    private func loadDetailedSummary() async {
        guard let task else {
            generatedSummaryTaskId = nil
            generatedSummary = ""
            isLoadingSummary = false
            return
        }

        generatedSummaryTaskId = task.id
        generatedSummary = ""
        guard sourceKind(for: task) == .gmail else {
            isLoadingSummary = false
            return
        }

        isLoadingSummary = true
        defer {
            if self.task?.id == task.id {
                isLoadingSummary = false
            }
        }

        var cachedFallback = ""

        if let stored = await DatabaseManager.shared.loadCurrentChatSummary(chatId: task.chatId) {
            let cached = stored.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cached.isEmpty {
                cachedFallback = cached
                if cached.split(whereSeparator: \Character.isWhitespace).count >= 30 {
                    guard !Task.isCancelled, self.task?.id == task.id else { return }
                    generatedSummary = cached
                    return
                }
            }
        }

        guard !Task.isCancelled, self.task?.id == task.id else { return }
        guard aiService.isConfigured else {
            generatedSummary = cachedFallback
            return
        }
        let messages = await summaryMessages(for: task)
        guard !Task.isCancelled, self.task?.id == task.id else { return }
        guard !messages.isEmpty else {
            generatedSummary = cachedFallback
            return
        }

        do {
            let summary = try await aiService.emailSummary(
                subject: task.chatTitle,
                sender: displayPerson(for: task),
                messages: messages,
                myUserId: Int64(telegramService.currentUser?.id ?? 0)
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty, !Task.isCancelled, self.task?.id == task.id else { return }
            generatedSummary = summary
            await DatabaseManager.shared.saveChatSummary(
                chatId: task.chatId,
                title: task.chatTitle,
                summary: summary,
                throughMessageId: messages.map(\.id).max() ?? 0
            )
        } catch {
            // Reveal the best cached copy after the final attempt. If none
            // exists, the deterministic summary becomes the stable fallback.
            guard !Task.isCancelled, self.task?.id == task.id else { return }
            generatedSummary = cachedFallback
        }
    }

    @MainActor
    private func loadTaskEvidence() async {
        conversationEvidence = []
        evidenceHeader = nil
        guard let task else {
            isLoadingEvidence = false
            return
        }
        let source = sourceKind(for: task)
        guard source == .slack || source == .telegram else {
            isLoadingEvidence = false
            return
        }

        isLoadingEvidence = true
        let sourceMessageID = evidence.first?.messageId
        var records: [DatabaseManager.MessageRecord]
        if let sourceMessageID {
            records = await DatabaseManager.shared.loadMessagesAround(
                chatId: task.chatId,
                messageId: sourceMessageID,
                window: 15
            )
        } else {
            records = []
        }
        guard !Task.isCancelled, self.task?.id == task.id else { return }
        applyEvidence(records, sourceMessageID: sourceMessageID, task: task)
        isLoadingEvidence = false

        // Thread replies are absent from Slack channel history. If the source
        // is a reply we pass its known parent; if it is a possible root, Slack
        // can still return its replies. The cached channel context stays usable
        // while that on-demand read completes.
        guard source == .slack,
              let sourceMessageID,
              let sourceID = sourceRegistry.chat(id: task.chatId)?.source,
              let messageSource = sourceRegistry.source(for: sourceID) else { return }
        let threadRootID = DashboardTaskEvidencePresentation.threadRootID(
            records: records,
            sourceMessageID: sourceMessageID
        )
        _ = await messageSource.hydrateThread(
            messageId: sourceMessageID,
            threadRootId: threadRootID
        )
        guard !Task.isCancelled, self.task?.id == task.id else { return }
        records = await DatabaseManager.shared.loadMessagesAround(
            chatId: task.chatId,
            messageId: sourceMessageID,
            window: 15
        )
        guard !Task.isCancelled, self.task?.id == task.id else { return }
        applyEvidence(records, sourceMessageID: sourceMessageID, task: task)
    }

    @MainActor
    private func applyEvidence(
        _ records: [DatabaseManager.MessageRecord],
        sourceMessageID: Int64?,
        task: DashboardTask
    ) {
        conversationEvidence = DashboardTaskEvidencePresentation.items(
            records: records,
            sourceMessageID: sourceMessageID,
            fallback: evidence
        )
        evidenceHeader = DashboardTaskEvidencePresentation.header(
            channelName: task.chatTitle,
            records: records,
            sourceMessageID: sourceMessageID,
            source: sourceKind(for: task)
        )
    }

    private func summaryMessages(for task: DashboardTask) async -> [TGMessage] {
        let records = await DatabaseManager.shared.loadMessages(chatId: task.chatId, limit: 6)
        let cached = records.compactMap { record -> TGMessage? in
            guard let rawText = record.textContent,
                  !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let text = GmailPresentation.compactBody(
                subject: task.chatTitle,
                messageText: rawText,
                maxCharacters: 6_000
            )
            return TGMessage(
                id: record.id,
                chatId: task.chatId,
                senderId: record.senderUserId.map { .user($0) } ?? .chat(task.chatId),
                date: record.date,
                textContent: text,
                mediaType: nil,
                isOutgoing: record.isOutgoing,
                chatTitle: task.chatTitle,
                senderName: record.senderName
            )
        }
        if !cached.isEmpty { return cached.sorted { $0.date < $1.date } }

        return evidence.map { source in
            TGMessage(
                id: source.messageId,
                chatId: source.chatId,
                senderId: .chat(source.chatId),
                date: source.date,
                textContent: GmailPresentation.compactBody(
                    subject: task.chatTitle,
                    messageText: source.text,
                    maxCharacters: 6_000
                ),
                mediaType: nil,
                isOutgoing: false,
                chatTitle: task.chatTitle,
                senderName: source.senderName
            )
        }.sorted { $0.date < $1.date }
    }

    @ViewBuilder
    private func taskActions(_ task: DashboardTask) -> some View {
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

    private func sourceOpenButton(_ task: DashboardTask, height: CGFloat) -> some View {
        let source = sourceKind(for: task)
        return Button {
            if chatOpenState.openingChatId == nil { onOpenChat(task.chatId) }
        } label: {
            Group {
                if chatOpenState.openingChatId == task.chatId {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Open", systemImage: source.systemImage)
                }
            }
            .font(PidgyDashboardTheme.metadataMediumFont)
            .padding(.horizontal, height == 30 ? 12 : 0)
            .frame(minWidth: 68)
            .frame(height: height)
            .contentShape(RoundedRectangle(cornerRadius: height == 30 ? 9 : 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(PidgyDashboardTheme.primary)
        .pidgyCapsuleBackground()
        .fixedSize(horizontal: true, vertical: false)
        .disabled(chatOpenState.openingChatId == task.chatId)
        .help("Open in \(source.displayName)")
    }

    private func sourceKind(for task: DashboardTask) -> MessageSourceKind {
        sourceRegistry.chat(id: task.chatId)?.source.kind ?? .telegram
    }

    private func gmailPreviewTarget(for task: DashboardTask) -> GmailPreviewTarget? {
        guard let source = sourceRegistry.chat(id: task.chatId)?.source,
              source.kind == .gmail,
              let messageID = evidence.first?.messageId else { return nil }
        return GmailPreviewTarget(source: source, messageID: messageID)
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

}

private struct GmailPreviewTarget {
    let source: SourceID
    let messageID: Int64
}

enum DashboardTaskEvidencePresentation {
    static func items(
        records: [DatabaseManager.MessageRecord],
        sourceMessageID: Int64?,
        fallback: [DashboardTaskSourceMessage]
    ) -> [EvidenceContextItem] {
        let fallbackByID = Dictionary(uniqueKeysWithValues: fallback.map { ($0.messageId, $0) })
        let loaded = records.compactMap { record -> EvidenceContextItem? in
            let storedText = record.textContent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let text: String
            if !storedText.isEmpty {
                text = storedText
            } else if let media = record.mediaTypeRaw, !media.isEmpty {
                text = "[\(media)]"
            } else {
                return nil
            }
            let fallbackSender = fallbackByID[record.id]?.senderName
            let storedSender = record.senderName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let storedFallback = fallbackSender?.trimmingCharacters(in: .whitespacesAndNewlines)
            let sender = record.isOutgoing
                ? "You"
                : (storedSender?.isEmpty == false ? storedSender : nil)
                    ?? (storedFallback?.isEmpty == false ? storedFallback : nil)
                    ?? "Someone"
            return EvidenceContextItem(
                id: record.id,
                date: record.date,
                senderName: sender,
                isOutgoing: record.isOutgoing,
                text: text,
                isSource: record.id == sourceMessageID
            )
        }
        if !loaded.isEmpty {
            return loaded.sorted {
                if $0.date != $1.date { return $0.date < $1.date }
                return $0.id < $1.id
            }
        }
        return fallback.map { item in
            EvidenceContextItem(
                id: item.messageId,
                date: item.date,
                senderName: item.senderName,
                isOutgoing: false,
                text: item.text,
                isSource: item.messageId == sourceMessageID
            )
        }.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.id < $1.id
        }
    }

    static func threadRootID(
        records: [DatabaseManager.MessageRecord],
        sourceMessageID: Int64
    ) -> Int64? {
        if let source = records.first(where: { $0.id == sourceMessageID }),
           let parent = source.threadRootId {
            return parent
        }
        return records.contains(where: { $0.threadRootId == sourceMessageID })
            ? sourceMessageID
            : nil
    }

    static func header(
        channelName: String,
        records: [DatabaseManager.MessageRecord],
        sourceMessageID: Int64?,
        source: MessageSourceKind
    ) -> DashboardEvidenceContextHeader {
        guard source == .slack,
              let sourceMessageID,
              let rootID = threadRootID(records: records, sourceMessageID: sourceMessageID)
        else {
            return DashboardEvidenceContextHeader(channelName: channelName, threadTitle: nil)
        }
        let rawRootText = records.first(where: { $0.id == rootID }).flatMap { $0.textContent }
        let rootText = rawRootText?.trimmingCharacters(in: .whitespacesAndNewlines)
        return DashboardEvidenceContextHeader(
            channelName: channelName,
            threadTitle: rootText.flatMap(compactThreadTitle)
        )
    }

    private static func compactThreadTitle(_ value: String) -> String? {
        let normalized = value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        guard normalized.count > 90 else { return normalized }
        let boundary = normalized.index(normalized.startIndex, offsetBy: 90)
        let prefix = String(normalized[..<boundary])
        let clipped = prefix.lastIndex(of: " ").map { String(prefix[..<$0]) } ?? prefix
        return clipped + "…"
    }
}

struct DashboardEvidenceContextHeader: Equatable {
    let channelName: String
    let threadTitle: String?
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
                    .lineLimit(item.isSource ? 8 : 4)
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

struct DashboardEvidenceConversationView: View {
    let items: [EvidenceContextItem]
    let sourceMessageID: Int64?
    let header: DashboardEvidenceContextHeader?

    private var scrollIdentity: String {
        items.map { String($0.id) }.joined(separator: ":")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header {
                VStack(alignment: .leading, spacing: 4) {
                    Label(normalizedChannel(header.channelName), systemImage: "number")
                        .font(PidgyDashboardTheme.metadataMediumFont)
                        .foregroundStyle(PidgyDashboardTheme.primary)
                        .lineLimit(1)

                    if let threadTitle = header.threadTitle {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(PidgyDashboardTheme.tertiary)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Thread")
                                    .font(.system(size: 9, weight: .semibold))
                                    .tracking(0.5)
                                    .textCase(.uppercase)
                                    .foregroundStyle(PidgyDashboardTheme.tertiary)
                                Text(threadTitle)
                                    .font(PidgyDashboardTheme.metadataFont)
                                    .foregroundStyle(PidgyDashboardTheme.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                Rectangle()
                    .fill(PidgyDashboardTheme.rule)
                    .frame(height: 1)
            }

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(items) { item in
                            DashboardEvidenceContextRow(item: item)
                                .id(item.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
                }
                .frame(height: 360)
                .task(id: scrollIdentity) {
                    guard let sourceMessageID else { return }
                    await Task.yield()
                    proxy.scrollTo(sourceMessageID, anchor: .center)
                }
            }
        }
        .background(PidgyDashboardTheme.paper.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(PidgyDashboardTheme.rule)
        )
    }

    private func normalizedChannel(_ rawValue: String) -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.hasPrefix("#") ? String(value.dropFirst()) : value
    }
}

struct GmailEmailPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let source: SourceID
    let sourceMessageID: Int64

    @State private var document: GmailPreviewDocument?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "envelope.open.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(PidgyDashboardTheme.brand)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(PidgyDashboardTheme.brand.opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(document?.subject ?? "Email preview")
                        .font(PidgyDashboardTheme.titleFont)
                        .foregroundStyle(PidgyDashboardTheme.primary)
                        .lineLimit(2)
                    if let document {
                        Text("\(document.sender)  ·  \(DateFormatting.dashboardListTimestamp(from: document.date))")
                            .font(PidgyDashboardTheme.metadataFont)
                            .foregroundStyle(PidgyDashboardTheme.secondary)
                            .lineLimit(1)
                    } else {
                        Text("Loading the original from Gmail…")
                            .font(PidgyDashboardTheme.metadataFont)
                            .foregroundStyle(PidgyDashboardTheme.secondary)
                    }
                }

                Spacer(minLength: 12)

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(PidgyDashboardTheme.secondary)
                .help("Close email preview")
            }
            .padding(18)

            Divider()

            Group {
                if let document {
                    VStack(spacing: 0) {
                        Label("Remote images and tracking are blocked", systemImage: "hand.raised.fill")
                            .font(PidgyDashboardTheme.metadataFont)
                            .foregroundStyle(PidgyDashboardTheme.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                            .background(PidgyDashboardTheme.raised)

                        GmailHTMLPreviewView(html: GmailPreviewHTML.sandboxed(document.html))
                    }
                } else if let errorMessage {
                    DashboardEmptyState(
                        systemImage: "exclamationmark.triangle",
                        title: "Preview unavailable",
                        subtitle: errorMessage
                    )
                } else {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.regular)
                        Text("Loading email…")
                            .font(PidgyDashboardTheme.metadataFont)
                            .foregroundStyle(PidgyDashboardTheme.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 760, height: 620)
        .background(PidgyDashboardTheme.paper)
        .task(id: "\(source.rawValue):\(sourceMessageID)") {
            do {
                document = try await GmailConnectionManager.shared.previewDocument(
                    source: source,
                    sourceMessageID: sourceMessageID
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

enum GmailPreviewHTML {
    static func sandboxed(_ original: String) -> String {
        let withoutActiveContent = original
            .replacingOccurrences(
                of: "(?is)<script[^>]*>.*?</script>",
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "(?is)<(iframe|object|embed)[^>]*>.*?</\\1>",
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "(?is)<meta[^>]+http-equiv=[\"']?refresh[\"']?[^>]*>",
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "(?is)<base[^>]*>",
                with: "",
                options: .regularExpression
            )

        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: cid:; style-src 'unsafe-inline'; font-src data:;">
          <style>
            :root { color-scheme: light; }
            html, body { margin: 0; min-height: 100%; background: #ffffff; }
            body { box-sizing: border-box; padding: 28px 32px; color: #202124; font: 15px/1.55 -apple-system, BlinkMacSystemFont, sans-serif; overflow-wrap: anywhere; }
            img { max-width: 100%; height: auto; }
            table { max-width: 100%; }
            pre { white-space: pre-wrap; font: inherit; margin: 0; }
            a { color: #2563c9; }
          </style>
        </head>
        <body>\(withoutActiveContent)</body>
        </html>
        """
    }
}

struct GmailHTMLPreviewView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.allowsMagnification = true
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        view.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedHTML: String?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
        }
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
