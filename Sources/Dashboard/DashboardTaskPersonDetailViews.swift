import SwiftUI

struct DashboardTaskDetail: View {
    let task: DashboardTask?
    let evidence: [DashboardTaskSourceMessage]
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onUpdateStatus: (DashboardTask, DashboardTaskStatus, Date?) -> Void
    let onOpenChat: (Int64) -> Void
    let onClose: () -> Void

    var body: some View {
        DashboardDetailPane(onClose: onClose) {
            if let task {
                DashboardDetailCover {
                    DashboardTopicChip(text: task.topicName ?? "Uncategorized", tint: topicTint(for: task))
                    Text(task.title)
                        .font(PidgyDashboardTheme.titleFont)
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

                DashboardDetailSection(title: "Evidence", trailing: "\(evidence.count) snippet\(evidence.count == 1 ? "" : "s")") {
                    VStack(spacing: 8) {
                        if evidence.isEmpty {
                            Text("No source snippets were stored for this task.")
                                .font(PidgyDashboardTheme.detailBodyFont)
                                .foregroundStyle(PidgyDashboardTheme.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ForEach(evidence, id: \.self) { source in
                                DashboardEvidenceRow(source: source)
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
            } else {
                Button(action: onRefresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .foregroundStyle(PidgyDashboardTheme.primary)
    }

    private func displayPerson(for task: DashboardTask) -> String {
        task.personName.isEmpty ? task.ownerName : task.personName
    }
}

struct DashboardPersonDetail: View {
    @EnvironmentObject private var telegramService: TelegramService

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
        }
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
