import SwiftUI

struct DashboardHomePage: View {
    @EnvironmentObject private var telegramService: TelegramService
    @EnvironmentObject private var aiService: AIService

    let tasks: [DashboardTask]
    let followUpItems: [FollowUpItem]
    let isLoading: Bool
    let aiConfigured: Bool
    let onOpenTask: (DashboardTask) -> Void
    let onOpenReply: (FollowUpItem) -> Void

    // Pigeon flock is an opt-out via Settings → Display. When off we
    // fall back to the plain DashboardSquiggleDivider that used to
    // live here, so the layout stays identical and birds simply
    // disappear.
    @AppStorage(AppConstants.Preferences.showPigeonFlockKey) private var showPigeonFlock = true
    @StateObject private var askChat = AskPidgyChatModel()
    @State private var aiQuestion = ""
    @FocusState private var isAIBarFocused: Bool

    private var hasInlineConversation: Bool {
        !askChat.thread.isEmpty || askChat.isAnswering
    }

    private var feedItems: [DashboardFeedItem] {
        let actionableTasks = tasks.filter(\.isActionableNow)
        let taskItems = actionableTasks.map(DashboardFeedItem.task)
        // Tasks + reply are both views over the same open-loop facts, so a
        // loop would otherwise appear twice on this blended feed. Keep the
        // task and drop the reply duplicate (on_me/on_them = a loop the chat
        // already has a task for); quiet chats have no loop, so they stay.
        // Unconditional: with the memory engine OFF both views still project
        // the frozen last-known facts, so the duplicate exists there too.
        let chatsWithTasks = Set(actionableTasks.map(\.chatId))
        let replies = followUpItems.filter { item in
            item.category == .quiet || !chatsWithTasks.contains(item.chat.id)
        }
        let replyItems = replies.map(DashboardFeedItem.reply)
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

    private var remainingFeedItems: [DashboardFeedItem] {
        feedItems
    }

    private var needsYouCount: Int {
        feedItems.filter { $0.section == .onFire }.count
    }

    private var personalName: String {
        let firstName = telegramService.currentUser?.firstName
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return firstName.isEmpty ? "there" : firstName
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Still up"
        }
    }

    private var briefingLine: String {
        guard !feedItems.isEmpty else {
            return aiConfigured
                ? "I’m watching your connected sources. Nothing needs you right now."
                : "Connect an AI provider and I’ll sort what needs your attention."
        }
        if needsYouCount == 1 {
            return "I found one thing that needs attention. The rest can wait."
        }
        if needsYouCount > 1 {
            return "I found \(needsYouCount) things that need attention. The rest can wait."
        }
        return "I sorted \(feedItems.count) open loop\(feedItems.count == 1 ? "" : "s"). Nothing is urgent."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(greeting), \(personalName)")
                        .font(PidgyDashboardTheme.heroTitleFont)
                        .tracking(-0.7)
                        .foregroundStyle(PidgyDashboardTheme.primary)
                    Text(briefingLine)
                        .font(PidgyDashboardTheme.pageSubtitleFont)
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Group {
                        if showPigeonFlock {
                            DashboardPigeonFlock()
                        } else {
                            DashboardSquiggleDivider()
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(.bottom, 4)

                askPidgyBar
                    .padding(.top, 24)

                if feedItems.isEmpty && isLoading {
                    DashboardSkeletonRows(count: 7)
                        .padding(.top, 24)
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
                            let items = remainingFeedItems.filter { $0.section == section }
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

    private var askPidgyBar: some View {
        VStack(spacing: 0) {
            if hasInlineConversation {
                HStack(spacing: 10) {
                    PidgyMascotMark(size: 30)
                    Text("ASK PIDGY")
                        .font(PidgyDashboardTheme.captionMediumFont)
                        .foregroundStyle(PidgyDashboardTheme.brand)
                        .tracking(0.7)

                    Spacer()

                    Button {
                        askChat.reset()
                        aiQuestion = ""
                        isAIBarFocused = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(PidgyDashboardTheme.tertiary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Close conversation")
                }
                .padding(.horizontal, 16)
                .frame(height: 50)

                AskPidgyThreadView(model: askChat)
                    .frame(height: 250)

                Divider()
                    .overlay(PidgyDashboardTheme.rule)

                askPidgyComposer
                    .frame(minHeight: 58)
            } else {
                askPidgyComposer
                    .frame(minHeight: 82)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: PidgyRadius.lg, style: .continuous)
                .fill(PidgyDashboardTheme.raised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PidgyRadius.lg, style: .continuous)
                .stroke(
                    isAIBarFocused ? PidgyDashboardTheme.brand.opacity(0.65) : PidgyDashboardTheme.rule,
                    lineWidth: 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: PidgyRadius.lg, style: .continuous))
        .onTapGesture {
            if !hasInlineConversation {
                isAIBarFocused = true
            }
        }
        .animation(PidgyMotion.easeOutFast, value: isAIBarFocused)
        .animation(PidgyMotion.easeOut, value: hasInlineConversation)
    }

    private var askPidgyComposer: some View {
        HStack(spacing: 14) {
            if !hasInlineConversation {
                PidgyMascotMark(size: 38)
            }

            VStack(alignment: .leading, spacing: 4) {
                if !hasInlineConversation {
                    Text("ASK PIDGY")
                        .font(PidgyDashboardTheme.captionMediumFont)
                        .foregroundStyle(PidgyDashboardTheme.brand)
                        .tracking(0.7)
                }

                TextField(
                    hasInlineConversation
                        ? "Ask a follow-up…"
                        : "Ask about your Gmail, Slack, Telegram, or WhatsApp…",
                    text: $aiQuestion
                )
                .textFieldStyle(.plain)
                .font(PidgyDashboardTheme.rowEmphasisFont)
                .foregroundStyle(PidgyDashboardTheme.primary)
                .focused($isAIBarFocused)
                .onSubmit(submitAIQuestion)
                .disabled(!aiConfigured || askChat.isAnswering)
            }

            Spacer(minLength: 12)

            Button(action: submitAIQuestion) {
                Image(systemName: askChat.isAnswering ? "ellipsis" : "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(canSubmitAIQuestion ? PidgyDashboardTheme.primary : PidgyDashboardTheme.tertiary)
                    .frame(width: 30, height: 30)
                    .background(
                        Circle().fill(canSubmitAIQuestion ? PidgyDashboardTheme.brand : PidgyDashboardTheme.sidebar)
                    )
            }
            .buttonStyle(.pidgyPress)
            .disabled(!canSubmitAIQuestion)
            .help(aiConfigured ? "Ask Pidgy" : "Connect an AI provider in Preferences")
        }
        .padding(.horizontal, 16)
    }

    private var canSubmitAIQuestion: Bool {
        aiConfigured
            && !askChat.isAnswering
            && !aiQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitAIQuestion() {
        let question = aiQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSubmitAIQuestion, !question.isEmpty else { return }
        aiQuestion = ""
        if askChat.thread.isEmpty {
            askChat.start(with: question, aiService: aiService)
        } else {
            askChat.send(question, aiService: aiService)
        }
        isAIBarFocused = true
    }
}

struct DashboardReplyQueuePage: View {
    @EnvironmentObject private var attentionStore: AttentionStore
    let items: [FollowUpItem]
    let isLoading: Bool
    @Binding var selectedChatId: Int64?
    /// Re-projects the queue from the current open-loop facts. Top-bar
    /// button only; detail panes have no Refresh of their own.
    let onRefresh: () -> Void
    let onOpenChat: (TGChat, Int64?) -> Void

    @State private var filter: DashboardReplyFilter = .onMe
    @State private var searchText = ""
    @State private var isFactCrawlRunning = FactExtractionCoordinator.shared.isCrawling
    /// User-controlled sort direction. `true` = newest activity at
    /// the top (default, canonical messaging-app behaviour); `false`
    /// = oldest at the top (useful when triaging chats you've been
    /// ignoring longest). Persisted across launches.
    @AppStorage("pidgyReplyQueueNewestFirst") private var sortNewestFirst = true

    private var filteredItems: [FollowUpItem] {
        let categoryFiltered: [FollowUpItem]
        switch filter {
        case .onMe:
            categoryFiltered = items.filter { $0.category == .onMe }
        case .onThem:
            categoryFiltered = items.filter { $0.category == .onThem }
        case .quiet:
            categoryFiltered = items.filter { $0.category == .quiet }
        }

        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let searched: [FollowUpItem]
        if query.isEmpty {
            searched = categoryFiltered
        } else {
            searched = categoryFiltered.filter { item in
                if item.chat.title.lowercased().contains(query) { return true }
                if (item.suggestedAction ?? "").lowercased().contains(query) { return true }
                return item.lastMessage.displayText.lowercased().contains(query)
            }
        }

        // `timeSinceLastActivity` is "how long ago" — smaller means
        // more recent. Ascending = newest first (the default);
        // descending = oldest first.
        return searched.sorted { a, b in
            sortNewestFirst
                ? a.timeSinceLastActivity < b.timeSinceLastActivity
                : a.timeSinceLastActivity > b.timeSinceLastActivity
        }
    }

    private var selectedItem: FollowUpItem? {
        selectedChatId.flatMap { id in items.first { $0.chat.id == id } }
    }

    var body: some View {
        Group {
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
        .onReceive(FactExtractionCoordinator.shared.$isCrawling.removeDuplicates()) { crawling in
            isFactCrawlRunning = crawling
        }
    }

    private var centeredList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                controlsRow
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
            VStack(alignment: .leading, spacing: 12) {
                header
                controlsRow
            }
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
        // Title + progress only. Segmented filter + search live in
        // `controlsRow` below the title (Rahul's request: filters
        // moved out of the top-right corner so the title gets the
        // whole header line, and a search box sits next to them).
        VStack(alignment: .leading, spacing: 4) {
            Text("Reply queue")
                .font(PidgyDashboardTheme.pageTitleFont)
                .tracking(-0.6)
                .foregroundStyle(PidgyDashboardTheme.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(selectedItem == nil ? EdgeInsets(top: 0, leading: 8, bottom: 12, trailing: 8) : EdgeInsets())
    }

    /// Single row directly under the title:
    ///   [ON ME] [ON THEM] [QUIET]                          [🔍 Search]
    /// Segmented filter on the left, compact fixed-width search
    /// anchored on the right with a Spacer between. Counts on the
    /// segments reflect the unfiltered totals per category — they
    /// should not change when search narrows the visible list,
    /// otherwise the user can't see whether the other tabs have
    /// content.
    private var controlsRow: some View {
        HStack(spacing: 10) {
            DashboardSegmentedReplyFilter(
                selection: $filter,
                onMeCount: items.filter { $0.category == .onMe }.count,
                onThemCount: items.filter { $0.category == .onThem }.count,
                quietCount: items.filter { $0.category == .quiet }.count
            )

            Spacer(minLength: 12)

            sortToggle

            searchBox
                .frame(width: 220)
        }
        .padding(selectedItem == nil ? EdgeInsets(top: 4, leading: 8, bottom: 22, trailing: 8) : EdgeInsets(top: 4, leading: 0, bottom: 22, trailing: 0))
    }

    /// Compact icon+text button that flips the queue between
    /// newest-first and oldest-first. Sits to the immediate left of
    /// the search box so the row reads `[segments] … [sort] [search]`.
    /// The arrow indicates CURRENT direction; the label tells the
    /// user what they'll see.
    private var sortToggle: some View {
        Button {
            sortNewestFirst.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: sortNewestFirst ? "arrow.down" : "arrow.up")
                    .font(.system(size: 11, weight: .semibold))
                Text(sortNewestFirst ? "Newest" : "Oldest")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(PidgyDashboardTheme.secondary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(PidgyDashboardTheme.sidebar)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(PidgyDashboardTheme.rule, lineWidth: 1)
            )
        }
        .buttonStyle(.pidgyPress)
        .help(sortNewestFirst ? "Sorted newest first — click to flip" : "Sorted oldest first — click to flip")
    }

    private var searchBox: some View {
        // Shared component — same chrome as Topics/People/Tasks
        // search inputs, just at the .compact size variant.
        DashboardSearchField(placeholder: "Search", text: $searchText, size: .compact)
    }

    private var queueRows: some View {
        VStack(spacing: 0) {
            if filteredItems.isEmpty && (isLoading || (ContextLayer.enabled && !attentionStore.hasLoadedFactReplies)) {
                DashboardSkeletonRows(count: selectedItem == nil ? 9 : 7)
                    .padding(.top, 6)
            } else if filteredItems.isEmpty && !searchText.isEmpty {
                DashboardEmptyState(
                    systemImage: "magnifyingglass",
                    title: "No matches",
                    subtitle: "Try a different search or switch tabs."
                )
                .frame(maxWidth: .infinity)
                .padding(.top, 36)
            } else if filteredItems.isEmpty, ContextLayer.enabled, isFactCrawlRunning {
                // Mid-crawl an empty tab isn't "nothing to reply to" — say
                // what's actually happening instead of "try refreshing".
                DashboardPigeonLoader(
                    subtitle: "Messages waiting on you will queue up here as Pidgy reads your chats."
                )
                .frame(maxWidth: .infinity)
                .padding(.top, 36)
            } else if filteredItems.isEmpty {
                DashboardEmptyState(
                    systemImage: "checkmark.circle",
                    title: "All clear here",
                    subtitle: "Nothing in this tab right now."
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
                    // Right-click → native NSMenu with the per-chat
                    // actions. macOS users expect right-click menus to
                    // look native, so this intentionally uses the
                    // system context menu.
                    .contextMenu {
                        // Hide = suppress this chat in the reply queue
                        // only (sticky, reversible from Preferences).
                        Button("Hide from queue", systemImage: "eye.slash") {
                            attentionStore.excludeChat(id: item.chat.id)
                        }
                        // Archive = remove the chat from EVERY pipeline
                        // (reply queue + tasks), like a bot. Reversible
                        // from Preferences → Archived chats.
                        Button("Archive chat", systemImage: "archivebox") {
                            ArchivedChatsStore.shared.archive(item.chat.id)
                            attentionStore.dropChat(id: item.chat.id)
                            ToastCenter.shared.show(
                                "Archived \(item.chat.title). Remove it anytime from Preferences → Archived chats.",
                                icon: "archivebox"
                            )
                        }
                        Divider()
                        // Wrong category / bad suggestion → feedback
                        // sheet with the triage context as a removable
                        // attachment. Also saved locally as an eval
                        // fixture. See FlaggedAnswerFixture.
                        Button("Flag this triage…", systemImage: "flag") {
                            flagReplyTriage(item)
                        }
                    }
                }
            }
        }
    }

    private func flagReplyTriage(_ item: FollowUpItem) {
        FlaggedAnswerFixture.replyTriage(item).submitToFeedbackSheet()
    }
}

struct DashboardReplyDetail: View {
    @EnvironmentObject private var telegramService: TelegramService
    @EnvironmentObject private var aiService: AIService
    @ObservedObject private var gmailConnection = GmailConnectionManager.shared
    let item: FollowUpItem?
    let onOpenChat: (TGChat, Int64?) -> Void
    let onClose: () -> Void

    @State private var conversationContext: [DatabaseManager.MessageRecord] = []
    @State private var isLoadingContext = false
    @State private var isPreparingTrackedOpen = false
    /// Drives the inline spinner on "Open in chat" while the Telegram deep
    /// link resolves (a TDLib lookup that isn't instant on a cache miss).
    @ObservedObject private var chatOpenState = ChatOpenState.shared
    /// Sender display names resolved on-demand for group messages
    /// whose cached `senderName` was nil. Keyed by sender user id.
    /// Populated by `resolveMissingSenderNames`.
    @State private var resolvedSenderNames: [Int64: String] = [:]

    // Suggested replies (#20) — populated when the user taps
    // "Suggest replies". Held per-item so switching items resets.
    @State private var suggestedReplies: [String] = []
    @State private var isGeneratingReplies = false
    @State private var suggestedRepliesError: String?
    @State private var suggestedRepliesForChatId: Int64?

    // Catch-up summary (#21) — populated for QUIET items when the
    // user taps "Catch me up".
    @State private var storedSummary: EntitySummary?
    @State private var catchUpExpanded = false
    @State private var catchUpText: String = ""
    @State private var isGeneratingCatchUp = false
    @State private var catchUpError: String?
    @State private var catchUpForChatId: Int64?
    @State private var taskCreatedForChatId: Int64?
    @State private var isCreatingTask = false
    @State private var taskCreationError: String?

    /// Same cap as the Task Evidence section — enough to read the back-and-
    /// forth that triggered the suggestion without becoming a full transcript.
    private static let maxEvidenceRows = 5
    /// More history than `maxEvidenceRows` so the suggested-replies
    /// and catch-up prompts have enough context to be useful.
    private static let maxAIContextRows = 25

    var body: some View {
        DashboardDetailPane(onClose: onClose) {
            if let item {
                if item.chat.source.kind == .gmail {
                    gmailDetailContent(for: item)
                } else {
                    DashboardDetailCover {
                        DashboardTopicChip(text: item.category.rawValue, tint: categoryTint(item.category))
                        Text(item.chat.title)
                            .font(PidgyDashboardTheme.sectionTitleFont)
                            .tracking(-0.4)
                            .foregroundStyle(PidgyDashboardTheme.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Text(sourceLabel(for: item.chat))
                            Text("·")
                            // Age of the ASK (loop date), not the chat's last message.
                            Text(DateFormatting.compactRelativeTime(from: item.loopDate ?? item.lastMessage.date))
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

                    // One combined Assist section: "Catch me up" (rolling summary,
                    // revealed instantly on click) + "Suggest replies" side by
                    // side, instead of two stacked near-empty sections.
                    assistSection(for: item)

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
                                    Button {
                                        if item.chat.source.kind == .telegram {
                                            Task { await telegramService.openMessageInTelegram(chatId: item.chat.id, messageId: row.id) }
                                        } else {
                                            onOpenChat(item.chat, row.id)
                                        }
                                    } label: {
                                        DashboardEvidenceContextRow(item: row)
                                    }
                                    .buttonStyle(.pidgyPress)
                                    .help(openLabel(for: item.chat))
                                }
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
            // Primary action — the top-bar Refresh covers re-analysis.
            // Per-detail Refresh buttons were removed because the global
            // top-bar refresh is the one source of truth for the user.
            if let item, item.chat.source.kind == .gmail {
                gmailFooter(for: item)
            } else {
                HStack(spacing: 8) {
                Button {
                    if let item { openForReply(item) }
                } label: {
                    Group {
                        if let item {
                            if isPreparingTrackedOpen || chatOpenState.openingChatId == item.chat.id {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label(openLabel(for: item.chat), systemImage: openIcon(for: item.chat))
                            }
                        } else {
                            Label("Open", systemImage: "arrow.up.forward.app")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pidgyPress)
                .foregroundStyle(PidgyDashboardTheme.primary)
                .pidgyCapsuleBackground()
                .disabled(
                    isPreparingTrackedOpen
                        || item == nil
                        || (item.map { chatOpenState.openingChatId == $0.chat.id } ?? false)
                )

                if let item {
                    Button {
                        FlaggedAnswerFixture.replyTriage(item).submitToFeedbackSheet()
                    } label: {
                        Image(systemName: "flag")
                            .frame(width: 36, height: 36)
                            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                    .pidgyCapsuleBackground()
                    .help("Wrong category or suggestion? Flag this triage — you'll review what's shared before sending.")
                }
                }
            }
        }
        // Keyed on chat AND loop anchor: the item's identity is chat-stable, so
        // when a re-projection swaps the chat's loop in place (old one closed, a
        // new ask opened), the anchor changes without the chat changing — the
        // evidence window must reload around the NEW anchor.
        .task(id: "\(item?.chat.id ?? 0)-\(item?.loopSourceMessageId ?? 0)") {
            // Reset AI sections FIRST, before any await. The error
            // branches aren't chat-scoped, and loadConversationContext
            // awaits DB reads + TDLib name lookups — so if we reset
            // afterwards, the previous chat's error would render under
            // the newly-selected chat for the whole load window.
            suggestedReplies = []
            suggestedRepliesError = nil
            suggestedRepliesForChatId = nil
            catchUpText = ""
            catchUpError = nil
            catchUpForChatId = nil
            storedSummary = nil
            catchUpExpanded = false
            taskCreatedForChatId = nil
            taskCreationError = nil
            if let chatId = item?.chat.id {
                storedSummary = await DatabaseManager.shared.loadCurrentChatSummary(chatId: chatId)
            }
            await loadConversationContext()
            if let item,
               item.chat.source.kind == .gmail,
               storedSummary == nil,
               aiService.isConfigured {
                await generateGmailSummary(for: item)
            }
        }
    }

    // MARK: - Gmail detail

    @ViewBuilder
    private func gmailDetailContent(for item: FollowUpItem) -> some View {
        let sender = GmailPresentation.senderName(from: item.lastMessage.senderName)
        let age = DateFormatting.compactRelativeTime(from: item.loopDate ?? item.lastMessage.date)

        DashboardDetailCover {
            HStack(alignment: .top, spacing: 10) {
                DashboardIdentityAvatar(
                    chat: item.chat,
                    label: sender,
                    source: .gmail,
                    userID: item.lastMessage.senderUserId,
                    size: 40
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(sender)
                        .font(PidgyDashboardTheme.metadataMediumFont)
                        .foregroundStyle(PidgyDashboardTheme.primary)
                        .lineLimit(1)
                    Text(DashboardSourceMetadata.providerLine(source: .gmail, age: age))
                        .font(PidgyDashboardTheme.metadataFont)
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                        .lineLimit(1)
                    if let account = DashboardSourceMetadata.accountLabel(
                        source: .gmail,
                        account: item.chat.source.account,
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
                DashboardTopicChip(text: item.category.rawValue, tint: categoryTint(item.category))
                    .padding(.trailing, 22)
            }

            Text(item.chat.title)
                .font(PidgyDashboardTheme.sectionTitleFont)
                .tracking(-0.4)
                .foregroundStyle(PidgyDashboardTheme.primary)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack(alignment: .top, spacing: 12) {
            Image(systemName: gmailStatusIcon(for: item))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(gmailStatusTint(for: item))
                .frame(width: 28, height: 28)
                .background(gmailStatusTint(for: item).opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(gmailStatusTitle(for: item))
                    .font(PidgyDashboardTheme.metadataMediumFont)
                    .foregroundStyle(PidgyDashboardTheme.primary)
                Text(gmailStatusSubtitle(for: item))
                    .font(PidgyDashboardTheme.metadataFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .overlay(alignment: .bottom) { gmailDivider }

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("ACTIONS")
                    .font(PidgyDashboardTheme.captionMediumFont)
                    .tracking(0.8)
                    .foregroundStyle(PidgyDashboardTheme.secondary)

                Button {
                    Task { await createTask(from: item) }
                } label: {
                    if isCreatingTask {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 82)
                    } else {
                        Label(
                            taskCreatedForChatId == item.chat.id ? "Created" : "Create task",
                            systemImage: taskCreatedForChatId == item.chat.id ? "checkmark" : "plus"
                        )
                    }
                }
                .buttonStyle(.pidgyPress)
                .font(PidgyDashboardTheme.captionMediumFont)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .pidgyCapsuleBackground()
                .disabled(isCreatingTask || taskCreatedForChatId == item.chat.id)
            }

            if let taskCreationError {
                Text(taskCreationError)
                    .font(PidgyDashboardTheme.metadataFont)
                    .foregroundStyle(PidgyDashboardTheme.red)
            }
        }
        .padding(22)
        .overlay(alignment: .bottom) { gmailDivider }

        VStack(alignment: .leading, spacing: 10) {
            Text("SUMMARY")
                .font(PidgyDashboardTheme.captionMediumFont)
                .tracking(0.8)
                .foregroundStyle(PidgyDashboardTheme.secondary)

            gmailSummaryContent(for: item)
        }
        .padding(22)
    }

    @ViewBuilder
    private func gmailSummaryContent(for item: FollowUpItem) -> some View {
        if let storedSummary {
            gmailInlineSummary(storedSummary.summary)
        } else if catchUpForChatId == item.chat.id, !catchUpText.isEmpty {
            gmailInlineSummary(catchUpText)
        } else if isGeneratingCatchUp && catchUpForChatId == item.chat.id {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Summarizing…")
                    .font(PidgyDashboardTheme.metadataFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PidgyDashboardTheme.paper)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            gmailInlineSummary(gmailFallbackSummary(for: item))
        }
    }

    private func gmailInlineSummary(_ text: String) -> some View {
        Text(text)
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

    private func openForReply(_ item: FollowUpItem) {
        guard !isPreparingTrackedOpen,
              chatOpenState.openingChatId == nil else { return }
        isPreparingTrackedOpen = true

        Task { @MainActor in
            var isTracking = false
            if item.category == .onMe,
               let sourceMessageId = item.loopSourceMessageId {
                isTracking = await DatabaseManager.shared.recordReplyOpenIntent(
                    chatId: item.chat.id,
                    sourceMessageId: sourceMessageId,
                    // A Gmail chat already represents one exact mail thread.
                    // Slack/Telegram groups need an additional reply-root match.
                    requiresThreadMatch: item.chat.source.kind != .gmail
                        && !item.chat.chatType.isOneOnOne
                )
            }

            isPreparingTrackedOpen = false
            if isTracking {
                let confirmation: String
                if item.chat.source.kind == .gmail {
                    confirmation = "Watching this email thread for your reply"
                    GmailConnectionManager.shared.watchReplyThread(
                        source: item.chat.source,
                        chatId: item.chat.id
                    )
                } else if item.chat.chatType.isOneOnOne {
                    confirmation = "Watching for your reply"
                } else {
                    confirmation = "Watching this thread for your reply"
                }
                ToastCenter.shared.show(
                    confirmation,
                    icon: "scope"
                )
            }
            onOpenChat(item.chat, item.loopSourceMessageId)
        }
    }

    private func gmailFooter(for item: FollowUpItem) -> some View {
        HStack(spacing: 8) {
            Button {
                openForReply(item)
            } label: {
                Group {
                    if isPreparingTrackedOpen || chatOpenState.openingChatId == item.chat.id {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Open in Gmail", systemImage: "envelope")
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pidgyPress)
            .foregroundStyle(PidgyDashboardTheme.primary)
            .pidgyCapsuleBackground()
            .disabled(isPreparingTrackedOpen || chatOpenState.openingChatId == item.chat.id)

            Menu {
                Button("Copy summary", systemImage: "doc.on.doc") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(gmailDisplayedSummary(for: item), forType: .string)
                }
                Divider()
                Button("Flag triage", systemImage: "flag") {
                    FlaggedAnswerFixture.replyTriage(item).submitToFeedbackSheet()
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
            .help("More email actions")
        }
    }

    private var gmailDivider: some View {
        Rectangle()
            .fill(PidgyDashboardTheme.rule)
            .frame(height: 1)
    }

    private func gmailStatusTitle(for item: FollowUpItem) -> String {
        switch item.category {
        case .quiet: return "No action needed"
        case .onMe: return item.suggestedAction ?? "Reply needed"
        case .onThem: return "Waiting on them"
        }
    }

    private func gmailStatusSubtitle(for item: FollowUpItem) -> String {
        switch item.category {
        case .quiet: return "Pidgy marked this email as informational."
        case .onMe: return "This email expects an answer or action from you."
        case .onThem: return "Pidgy is tracking the response you are waiting for."
        }
    }

    private func gmailStatusIcon(for item: FollowUpItem) -> String {
        switch item.category {
        case .quiet: return "checkmark"
        case .onMe: return "arrowshape.turn.up.left.fill"
        case .onThem: return "clock.fill"
        }
    }

    private func gmailStatusTint(for item: FollowUpItem) -> Color {
        switch item.category {
        case .quiet: return Color.Pidgy.success
        case .onMe: return Color.Pidgy.warning
        case .onThem: return Color.Pidgy.accent
        }
    }

    private func gmailDisplayedSummary(for item: FollowUpItem) -> String {
        if let summary = storedSummary?.summary.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            return summary
        }
        let generated = catchUpText.trimmingCharacters(in: .whitespacesAndNewlines)
        if catchUpForChatId == item.chat.id, !generated.isEmpty {
            return generated
        }
        return gmailFallbackSummary(for: item)
    }

    private func gmailFallbackSummary(for item: FollowUpItem) -> String {
        let sender = GmailPresentation.senderName(from: item.lastMessage.senderName)
        let topic = item.chat.title.trimmingCharacters(in: .whitespacesAndNewlines)
        switch item.category {
        case .onMe:
            let action = item.suggestedAction?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let action, !action.isEmpty {
                return "\(sender) emailed about \(topic). \(action)"
            }
            return "\(sender) emailed about \(topic), and it needs your response or action."
        case .onThem:
            return "You are waiting for \(sender) to follow up about \(topic)."
        case .quiet:
            return "\(sender) shared an informational update about \(topic). No action is needed."
        }
    }

    private func generateGmailSummary(for item: FollowUpItem) async {
        catchUpError = nil
        isGeneratingCatchUp = true
        catchUpForChatId = item.chat.id
        defer { isGeneratingCatchUp = false }
        do {
            let messages = await loadAIContextMessages(for: item.chat.id)
            guard !messages.isEmpty else { return }
            let sender = GmailPresentation.senderName(from: item.lastMessage.senderName)
            let myUserId = telegramService.currentUser?.id ?? 0
            let summary = try await aiService.emailSummary(
                subject: item.chat.title,
                sender: sender,
                messages: messages,
                myUserId: Int64(myUserId)
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else { return }
            catchUpText = summary
            await DatabaseManager.shared.saveChatSummary(
                chatId: item.chat.id,
                title: item.chat.title,
                summary: summary,
                throughMessageId: item.lastMessage.id
            )
        } catch {
            // Keep the detail useful and body-free when AI is unavailable.
            catchUpError = error.localizedDescription
        }
    }

    @MainActor
    private func createTask(from item: FollowUpItem) async {
        guard !isCreatingTask else { return }
        isCreatingTask = true
        taskCreationError = nil
        defer { isCreatingTask = false }

        let existing = await DatabaseManager.shared.loadOpenFacts(chatId: item.chat.id)
            .first { fact in
                fact.predicate == .iOwe
                    && (item.loopSourceMessageId == nil || fact.sourceMessageId == item.loopSourceMessageId)
            }
        let sender = GmailPresentation.senderName(from: item.lastMessage.senderName)
        let body = GmailPresentation.compactBody(
            subject: item.chat.title,
            messageText: item.lastMessage.displayText
        )

        let draft: FactDraft
        if let existing {
            draft = FactDraft(
                subjectEntity: existing.subjectEntity,
                subjectPersonId: existing.subjectPersonId,
                predicate: .iOwe,
                objectText: existing.objectText,
                action: existing.action.isEmpty ? "Review \(item.chat.title)" : existing.action,
                loopKind: .action,
                objectEntity: existing.objectEntity,
                confidence: max(existing.confidence, 0.95),
                validFrom: existing.validFrom,
                sourceChatId: existing.sourceChatId,
                sourceChatTitle: existing.sourceChatTitle,
                sourceMessageId: existing.sourceMessageId,
                sourceText: existing.sourceText,
                senderName: existing.senderName
            )
        } else {
            draft = FactDraft(
                subjectEntity: sender,
                predicate: .iOwe,
                objectText: item.chat.title,
                action: "Review \(item.chat.title)",
                loopKind: .action,
                confidence: 1,
                validFrom: item.lastMessage.date,
                sourceChatId: item.chat.id,
                sourceChatTitle: item.chat.title,
                sourceMessageId: item.lastMessage.id,
                sourceText: body,
                senderName: sender
            )
        }

        await DatabaseManager.shared.upsertFacts([draft])
        taskCreatedForChatId = item.chat.id
        NotificationCenter.default.post(name: .contextFactsChanged, object: nil)
    }

    // MARK: - Assist section (catch-up + suggested replies, #20/#21)

    /// One "Assist" section: both AI helpers side by side as buttons, each
    /// revealing its content in place — replaces the two stacked sections
    /// that were mostly empty chrome.
    @ViewBuilder
    private func assistSection(for item: FollowUpItem) -> some View {
        let offersCatchUp = storedSummary != nil || item.category == .quiet
        let offersReplies = item.category != .quiet
        let showCatchUpButton = offersCatchUp
            && !(storedSummary != nil && catchUpExpanded)
            && !(catchUpForChatId == item.chat.id && (isGeneratingCatchUp || !catchUpText.isEmpty))
        let showRepliesButton = offersReplies
            && !(suggestedRepliesForChatId == item.chat.id && (isGeneratingReplies || !suggestedReplies.isEmpty))

        DashboardDetailSection(title: "Assist") {
            VStack(alignment: .leading, spacing: 10) {
                if !aiService.isConfigured {
                    Text("Connect an AI provider in Preferences to enable summaries and reply drafts.")
                        .font(PidgyDashboardTheme.detailBodyFont)
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                } else {
                    if showCatchUpButton || showRepliesButton {
                        HStack(spacing: 8) {
                            if showCatchUpButton {
                                assistButton("Catch me up", icon: "sparkles") {
                                    if storedSummary != nil {
                                        catchUpExpanded = true
                                    } else {
                                        Task { await generateCatchUpSummary(for: item) }
                                    }
                                }
                            }
                            if showRepliesButton {
                                assistButton("Suggest replies", icon: "text.bubble") {
                                    Task { await generateSuggestedReplies(for: item) }
                                }
                            }
                        }
                    }
                    if offersCatchUp { catchUpContent(for: item) }
                    if offersReplies { repliesContent(for: item) }
                }
            }
        }
    }

    private func assistButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(PidgyDashboardTheme.captionMediumFont)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .pidgyCapsuleBackground()
        }
        .buttonStyle(.plain)
        .foregroundStyle(PidgyDashboardTheme.primary)
    }

    @ViewBuilder
    private func repliesContent(for item: FollowUpItem) -> some View {
        if let error = suggestedRepliesError {
            Text(error)
                .font(PidgyDashboardTheme.detailBodyFont)
                .foregroundStyle(PidgyDashboardTheme.red)
        } else if suggestedRepliesForChatId == item.chat.id && !suggestedReplies.isEmpty {
            ForEach(Array(suggestedReplies.enumerated()), id: \.offset) { _, reply in
                suggestedReplyChip(reply)
            }
            Button {
                Task { await generateSuggestedReplies(for: item) }
            } label: {
                Label("Regenerate", systemImage: "arrow.clockwise")
                    .font(PidgyDashboardTheme.captionMediumFont)
            }
            .buttonStyle(.pidgyPress)
            .foregroundStyle(PidgyDashboardTheme.secondary)
            .padding(.top, 2)
        } else if isGeneratingReplies && suggestedRepliesForChatId == item.chat.id {
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.6)
                Text("Drafting 3 options…")
                    .font(PidgyDashboardTheme.detailBodyFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
            }
        }
    }

    private func suggestedReplyChip(_ reply: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(reply)
                .font(PidgyDashboardTheme.detailBodyFont)
                .foregroundStyle(PidgyDashboardTheme.primary)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(reply, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(PidgyDashboardTheme.tertiary)
                    .padding(6)
                    .background(
                        Circle().fill(PidgyDashboardTheme.sidebar)
                    )
            }
            .buttonStyle(.plain)
            .help("Copy to clipboard")
        }
        .padding(12)
        .background(PidgyDashboardTheme.paper)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(PidgyDashboardTheme.rule)
        )
    }

    private func generateSuggestedReplies(for item: FollowUpItem) async {
        suggestedRepliesError = nil
        isGeneratingReplies = true
        suggestedRepliesForChatId = item.chat.id
        defer { isGeneratingReplies = false }
        do {
            let messages = await loadAIContextMessages(for: item.chat.id)
            guard !messages.isEmpty else {
                suggestedRepliesError = "No recent messages to draft from."
                suggestedReplies = []
                return
            }
            let myUserId = telegramService.currentUser?.id ?? 0
            let replies = try await aiService.suggestReplies(
                chatTitle: item.chat.title,
                messages: messages,
                myUserId: Int64(myUserId)
            )
            if replies.isEmpty {
                suggestedRepliesError = "The model returned no usable replies."
            } else {
                suggestedReplies = replies
            }
        } catch {
            suggestedRepliesError = error.localizedDescription
            suggestedReplies = []
        }
    }

    // MARK: - Catch-up content (rolling summary; on-demand fallback)

    @ViewBuilder
    private func catchUpContent(for item: FollowUpItem) -> some View {
        if let stored = storedSummary, catchUpExpanded {
            // Rolling summary from entity memory: revealed on click,
            // instantly (no AI call — folded in the background).
            Text(stored.summary)
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
            Text("Rolling summary · updated \(DateFormatting.compactRelativeTime(from: stored.validFrom))")
                .font(PidgyDashboardTheme.metadataFont)
                .foregroundStyle(PidgyDashboardTheme.tertiary)
        } else if let error = catchUpError {
            Text(error)
                .font(PidgyDashboardTheme.detailBodyFont)
                .foregroundStyle(PidgyDashboardTheme.red)
        } else if catchUpForChatId == item.chat.id && !catchUpText.isEmpty {
            Text(catchUpText)
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
        } else if isGeneratingCatchUp && catchUpForChatId == item.chat.id {
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.6)
                Text("Summarizing the last week…")
                    .font(PidgyDashboardTheme.detailBodyFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
            }
        }
    }

    private func generateCatchUpSummary(for item: FollowUpItem) async {
        catchUpError = nil
        isGeneratingCatchUp = true
        catchUpForChatId = item.chat.id
        defer { isGeneratingCatchUp = false }
        do {
            let messages = await loadAIContextMessages(for: item.chat.id)
            guard !messages.isEmpty else {
                catchUpError = "No recent messages to summarize."
                return
            }
            let myUserId = telegramService.currentUser?.id ?? 0
            let summary = try await aiService.catchUpSummary(
                chatTitle: item.chat.title,
                messages: messages,
                myUserId: Int64(myUserId)
            )
            catchUpText = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if catchUpText.isEmpty {
                catchUpError = "The model returned an empty summary."
            }
        } catch {
            catchUpError = error.localizedDescription
        }
    }

    /// Loads ~25 recent messages for an AI prompt and converts them
    /// into TGMessage. Returns `[]` if the chat isn't cached locally
    /// (e.g. user opened a chat the indexer hasn't reached yet).
    private func loadAIContextMessages(for chatId: Int64) async -> [TGMessage] {
        let records = await DatabaseManager.shared.loadMessages(
            chatId: chatId,
            limit: Self.maxAIContextRows
        )
        return records.compactMap { record -> TGMessage? in
            guard let text = record.textContent,
                  !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            // Map the real sender user id when we have it (same as
            // SummaryEngine / TaskIndexCoordinator / PersonProfileService),
            // falling back to the chat id for anonymous senders. This
            // keeps per-user [ME] attribution correct even if a caller
            // later passes a real myUserId.
            let senderId: TGMessage.MessageSenderId = record.senderUserId
                .map { .user($0) } ?? .chat(chatId)
            return TGMessage(
                id: record.id,
                chatId: chatId,
                senderId: senderId,
                date: record.date,
                textContent: text,
                mediaType: nil,
                isOutgoing: record.isOutgoing,
                chatTitle: nil,
                senderName: record.senderName
            )
        }.sorted { $0.date < $1.date }
    }

    private func loadConversationContext() async {
        guard let chatId = item?.chat.id else {
            conversationContext = []
            return
        }
        isLoadingContext = true
        defer { isLoadingContext = false }
        // Anchor on the loop's trigger message (the reason this chat is ON ME)
        // so Evidence shows the conversation around it, not the chat's latest
        // unrelated messages. QUIET items have no loop → fall back to recent.
        let recent: [DatabaseManager.MessageRecord]
        if let anchor = item?.loopSourceMessageId, anchor > 0 {
            recent = await DatabaseManager.shared.loadMessagesAround(
                chatId: chatId,
                messageId: anchor,
                window: Self.maxEvidenceRows
            )
        } else {
            recent = await DatabaseManager.shared.loadMessages(
                chatId: chatId,
                limit: Self.maxEvidenceRows + 2
            )
        }
        conversationContext = recent.sorted { $0.date < $1.date }
        await resolveMissingSenderNames(in: recent)
    }

    /// Group-chat messages frequently have a nil `senderName` in the
    /// local cache (the message was stored before its sender's user
    /// record was fetched), which used to render as "Unknown" in the
    /// right-hand detail pane. Resolve those names from TelegramService
    /// (cache, then a TDLib fetch) and stash them keyed by sender user
    /// id so the synchronous row builders can pick them up.
    private func resolveMissingSenderNames(in records: [DatabaseManager.MessageRecord]) async {
        let unresolved = Set(
            records
                .filter { ($0.senderName?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) && !$0.isOutgoing }
                .compactMap { $0.senderUserId }
        )
        guard !unresolved.isEmpty else { return }
        var resolved = resolvedSenderNames
        var freshlyResolved: [Int64: String] = [:]
        for userId in unresolved where resolved[userId] == nil {
            if let name = await telegramService.resolveDisplayName(for: userId) {
                resolved[userId] = name
                freshlyResolved[userId] = name
            }
        }
        if resolved != resolvedSenderNames {
            resolvedSenderNames = resolved
        }
        // Heal the cache permanently: a name resolved once shouldn't need
        // re-resolving on every view (or render as "Someone" in surfaces
        // that read the DB directly).
        if !freshlyResolved.isEmpty {
            await DatabaseManager.shared.backfillSenderNames(freshlyResolved)
        }
    }

    /// Treats the FollowUpItem's `lastMessage` as the "source" — it's the
    /// message that drove the categorization. Surrounding chat history is
    /// loaded from the DB and rendered as context. Falls back to a one-row
    /// list with just the last message if the DB hasn't cached the chat yet.
    private func mergedEvidenceItems(for item: FollowUpItem) -> [EvidenceContextItem] {
        // Source = the loop's trigger message (why this chat is ON ME) when we
        // have it; QUIET items fall back to the chat's last message.
        let sourceId = item.loopSourceMessageId ?? item.lastMessage.id
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

        // Prefer the real loop-source record from the loaded window (true sender
        // + text); else the stored evidence text; else the chat's last message.
        let source: EvidenceContextItem
        if let rec = conversationContext.first(where: { $0.id == sourceId }) {
            source = EvidenceContextItem(
                id: rec.id,
                date: rec.date,
                senderName: senderLabel(for: rec),
                isOutgoing: rec.isOutgoing,
                text: nonEmptyDisplayText(for: rec),
                isSource: true
            )
        } else if let evidence = item.loopEvidence, !evidence.isEmpty {
            // The anchor record isn't in the loaded window — render the stored
            // loop: ITS date (age of the ask, so it sorts chronologically) and
            // ITS person (the asker), never the chat's unrelated last message.
            source = EvidenceContextItem(
                id: sourceId,
                date: item.loopDate ?? item.lastMessage.date,
                senderName: item.loopPersonName ?? sourceSenderLabel(for: item),
                isOutgoing: false,
                text: evidence,
                isSource: true
            )
        } else {
            let fallbackText = item.chat.source.kind == .gmail
                ? GmailPresentation.preview(subject: item.chat.title, messageText: item.lastMessage.displayText)
                : item.lastMessage.displayText
            source = EvidenceContextItem(
                id: sourceId,
                date: item.lastMessage.date,
                senderName: sourceSenderLabel(for: item),
                isOutgoing: item.lastMessage.isOutgoing,
                text: fallbackText.isEmpty ? item.chat.title : fallbackText,
                isSource: true
            )
        }

        return (context + [source]).sorted { $0.date < $1.date }
    }

    private func senderLabel(for record: DatabaseManager.MessageRecord) -> String {
        if record.isOutgoing { return "You" }
        let trimmed = record.senderName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return item?.chat.source.kind == .gmail
                ? GmailPresentation.senderName(from: trimmed)
                : trimmed
        }
        // Fall back to a name we resolved on-demand for group
        // messages whose cached senderName was nil.
        if let userId = record.senderUserId, let resolved = resolvedSenderNames[userId] {
            return resolved
        }
        // No sender USER at all = a sent-as-channel / anonymous-admin post —
        // Telegram itself shows those under the chat's name.
        if record.senderUserId == nil, let item {
            return item.chat.title
        }
        return unknownSenderFallback
    }

    private func sourceSenderLabel(for item: FollowUpItem) -> String {
        if item.lastMessage.isOutgoing { return "You" }
        let trimmed = item.lastMessage.senderName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return item.chat.source.kind == .gmail
                ? GmailPresentation.senderName(from: trimmed)
                : trimmed
        }
        if let userId = item.lastMessage.senderUserId, let resolved = resolvedSenderNames[userId] {
            return resolved
        }
        return unknownSenderFallback
    }

    /// Graceful last resort when a sender name truly can't be
    /// resolved (anonymous group admin, or a user TDLib won't return).
    /// For a 1:1 DM the other party IS the chat, so use the chat
    /// title; for a group, "Someone" reads far less broken than the
    /// old bare "Unknown".
    private var unknownSenderFallback: String {
        guard let item else { return "Someone" }
        return item.chat.chatType.isPrivate ? item.chat.title : "Someone"
    }

    private func nonEmptyDisplayText(for record: DatabaseManager.MessageRecord) -> String {
        let trimmed = record.textContent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            if let item, item.chat.source.kind == .gmail {
                let preview = GmailPresentation.preview(subject: item.chat.title, messageText: trimmed)
                return preview.isEmpty ? item.chat.title : preview
            }
            return trimmed
        }
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

    private func sourceLabel(for chat: TGChat) -> String {
        chat.source.kind == .telegram ? chat.chatType.displayName : chat.source.kind.displayName
    }

    private func openLabel(for chat: TGChat) -> String {
        chat.source.kind == .telegram ? "Open in chat" : "Open in \(chat.source.kind.displayName)"
    }

    private func openIcon(for chat: TGChat) -> String {
        switch chat.source.kind {
        case .telegram: return "paperplane"
        case .gmail: return "envelope"
        case .slack: return "number"
        case .whatsapp: return "bubble.left.and.bubble.right"
        }
    }
}

struct DashboardFeedRow: View {
    @EnvironmentObject private var sourceRegistry: SourceRegistry

    let item: DashboardFeedItem

    var body: some View {
        HStack(spacing: 12) {
            DashboardIdentityAvatar(
                chat: chat,
                label: personName,
                source: chat?.source.kind,
                userID: identityUserID,
                size: PidgyDashboardTheme.rowAvatarSize
            )

            // Match Tasks and Reply Queue: identity/provenance first, then the
            // concise action. Raw Gmail subjects and generic topic labels do
            // not help the user decide what to do next.
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(personName)
                        .font(PidgyDashboardTheme.rowEmphasisFont)
                        .foregroundStyle(PidgyDashboardTheme.primary)
                        .lineLimit(1)
                        .layoutPriority(1)

                    if let source = chat?.source.kind {
                        DashboardInlineSourceLabel(source: source)
                    }

                    if let conversationContext {
                        Text("·")
                            .foregroundStyle(PidgyDashboardTheme.tertiary)
                        Text(conversationContext)
                            .font(PidgyDashboardTheme.detailBodyFont)
                            .foregroundStyle(PidgyDashboardTheme.secondary)
                            .lineLimit(1)
                    }
                }

                Text(item.title)
                    .font(PidgyDashboardTheme.detailBodyFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
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
        .pidgyRow()
    }

    private var conversationContext: String? {
        guard let chat,
              chat.source.kind != .gmail,
              !chat.chatType.isPrivate
        else { return nil }
        guard let title = DashboardTaskPresentation.displayConversationTitle(
            item.chat,
            source: chat.source.kind
        ),
              !DashboardTaskPresentation.sameIdentity(title, personName)
        else { return nil }
        return title
    }

    private var personName: String {
        guard chat?.source.kind == .gmail else { return item.person }
        return GmailPresentation.senderName(from: item.person)
    }

    private var chat: TGChat? {
        switch item.kind {
        case .reply(let reply):
            return reply.chat
        case .task(let task):
            return sourceRegistry.chat(id: task.chatId)
        }
    }

    private var identityUserID: Int64? {
        switch item.kind {
        case .reply(let reply):
            return reply.lastMessage.senderUserId
        case .task:
            guard let message = chat?.lastMessage,
                  DashboardTaskPresentation.sameIdentity(message.senderName, personName)
            else { return nil }
            return message.senderUserId
        }
    }
}

struct DashboardAttentionRow: View {
    let item: FollowUpItem
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            DashboardIdentityAvatar(
                chat: item.chat,
                label: personName,
                source: item.chat.source.kind,
                userID: item.lastMessage.senderUserId,
                size: PidgyDashboardTheme.rowAvatarSize
            )

            VStack(alignment: .leading, spacing: 4) {
                if isGmail {
                    gmailContent
                } else {
                    conversationContent
                }
            }

            Spacer(minLength: 12)

            Text(DateFormatting.compactRelativeTime(from: item.loopDate ?? item.lastMessage.date))
                .font(PidgyDashboardTheme.monoTimestampFont)
                .foregroundStyle(item.category == .onMe ? PidgyDashboardTheme.brand : PidgyDashboardTheme.secondary)
                .frame(width: PidgyDashboardTheme.timestampColumnWidth, alignment: .trailing)
        }
        .padding(.horizontal, PidgyDashboardTheme.rowHorizontalPadding)
        .frame(height: 58)
        .pidgyRow(isSelected: isSelected)
    }

    private var personName: String {
        if isGmail {
            return GmailPresentation.senderName(from: item.lastMessage.senderName)
        }
        return item.chat.chatType.isPrivate ? item.chat.title : (item.lastMessage.senderName ?? item.chat.title)
    }

    private var isGmail: Bool { item.chat.source.kind == .gmail }

    private var gmailContent: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text(personName)
                    .font(PidgyDashboardTheme.rowEmphasisFont)
                    .foregroundStyle(PidgyDashboardTheme.primary)
                    .lineLimit(1)
                    .layoutPriority(1)
                DashboardInlineSourceLabel(source: item.chat.source.kind)
                if item.chat.unreadCount > 0 {
                    Circle()
                        .fill(PidgyDashboardTheme.brand)
                        .frame(width: 5, height: 5)
                        .accessibilityLabel("Unread")
                }
            }

            Text(item.suggestedAction ?? item.chat.title)
                .font(PidgyDashboardTheme.detailBodyFont)
                .foregroundStyle(PidgyDashboardTheme.secondary)
                .lineLimit(1)
        }
    }

    private var conversationContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(personName)
                    .font(PidgyDashboardTheme.rowEmphasisFont)
                    .foregroundStyle(PidgyDashboardTheme.primary)
                    .lineLimit(1)
                    .layoutPriority(1)
                DashboardInlineSourceLabel(source: item.chat.source.kind)
                if let conversationContext {
                    Text("·")
                        .foregroundStyle(PidgyDashboardTheme.tertiary)
                    Text(conversationContext)
                        .font(PidgyDashboardTheme.detailBodyFont)
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                        .lineLimit(1)
                }
            }

            Text(item.suggestedAction ?? item.lastMessage.displayText)
                .font(PidgyDashboardTheme.detailBodyFont)
                .foregroundStyle(PidgyDashboardTheme.secondary)
                .lineLimit(1)
        }
    }

    /// DMs already use the conversation title as the person's identity, so
    /// repeating both the name and "DM" adds no information. Group/channel
    /// context remains visible when it is genuinely distinct from the person.
    private var conversationContext: String? {
        guard !item.chat.chatType.isPrivate else { return nil }
        guard let title = DashboardTaskPresentation.displayConversationTitle(
            item.chat.title,
            source: item.chat.source.kind
        ), !sameIdentity(title, personName) else { return nil }
        return title
    }

    private func sameIdentity(_ lhs: String, _ rhs: String) -> Bool {
        lhs.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        == rhs.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
            return "Needs attention"
        case .thisWeek:
            return "Up next"
        case .later:
            return "I’m keeping an eye on"
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
            avatarLabel: task.personName.isEmpty ? task.chatTitle : task.personName,
            date: task.latestSourceDate ?? task.updatedAt,
            section: section(for: task.priority),
            kind: .task(task)
        )
    }

    static func reply(_ item: FollowUpItem) -> DashboardFeedItem {
        let isGmail = item.chat.source.kind == .gmail
        let isPrivate = item.chat.chatType.isPrivate
        let person = isGmail
            ? GmailPresentation.senderName(from: item.lastMessage.senderName)
            : (isPrivate ? item.chat.title : item.lastMessage.senderName ?? item.chat.title)
        // For DMs the person column already names the contact, so the
        // chat slot shows the type tag ("DM") for context. For groups /
        // supergroups / channels, show the actual chat title — the
        // generic "Group" / "Supergroup" word was uninformative when
        // multiple group chats stacked in the feed.
        let chatLabel = isGmail ? "Gmail" : (isPrivate ? item.chat.chatType.displayName : item.chat.title)
        return DashboardFeedItem(
            id: "reply-\(item.chat.id)",
            title: item.suggestedAction ?? (isGmail ? item.chat.title : item.lastMessage.displayText),
            person: person,
            chat: chatLabel,
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
