import SwiftUI

struct DashboardHomePage: View {
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
    @EnvironmentObject private var attentionStore: AttentionStore
    let items: [FollowUpItem]
    let isLoading: Bool
    @Binding var selectedChatId: Int64?
    /// Re-projects the queue from the current open-loop facts. Top-bar
    /// button only; detail panes have no Refresh of their own.
    let onRefresh: () -> Void
    let onOpenChat: (TGChat) -> Void

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
    let item: FollowUpItem?
    let onOpenChat: (TGChat) -> Void
    let onClose: () -> Void

    @State private var conversationContext: [DatabaseManager.MessageRecord] = []
    @State private var isLoadingContext = false
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

    /// Same cap as the Task Evidence section — enough to read the back-and-
    /// forth that triggered the suggestion without becoming a full transcript.
    private static let maxEvidenceRows = 5
    /// More history than `maxEvidenceRows` so the suggested-replies
    /// and catch-up prompts have enough context to be useful.
    private static let maxAIContextRows = 25

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
                                    Task { await telegramService.openMessageInTelegram(chatId: item.chat.id, messageId: row.id) }
                                } label: {
                                    DashboardEvidenceContextRow(item: row)
                                }
                                .buttonStyle(.pidgyPress)
                                .help("Open this message in Telegram")
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
            HStack(spacing: 8) {
                Button {
                    if let item, chatOpenState.openingChatId == nil { onOpenChat(item.chat) }
                } label: {
                    Group {
                        if let item, chatOpenState.openingChatId == item.chat.id {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Open in chat", systemImage: "paperplane")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pidgyPress)
                .foregroundStyle(PidgyDashboardTheme.primary)
                .pidgyCapsuleBackground()
                .disabled(item.map { chatOpenState.openingChatId == $0.chat.id } ?? false)

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
            if let chatId = item?.chat.id {
                storedSummary = await DatabaseManager.shared.loadCurrentChatSummary(chatId: chatId)
            }
            await loadConversationContext()
        }
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
            source = EvidenceContextItem(
                id: sourceId,
                date: item.lastMessage.date,
                senderName: sourceSenderLabel(for: item),
                isOutgoing: item.lastMessage.isOutgoing,
                text: item.lastMessage.displayText,
                isSource: true
            )
        }

        return (context + [source]).sorted { $0.date < $1.date }
    }

    private func senderLabel(for record: DatabaseManager.MessageRecord) -> String {
        if record.isOutgoing { return "You" }
        let trimmed = record.senderName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
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
        if !trimmed.isEmpty { return trimmed }
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
        .pidgyRow()
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
