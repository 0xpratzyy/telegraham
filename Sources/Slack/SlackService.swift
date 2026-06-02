import Foundation
import Combine

/// A `MessageSource` backed by one Slack workspace. Created after a
/// successful OAuth connect with the workspace's team id + user token, it
/// fetches channels/DMs/messages/users and maps them into the source-tagged
/// `TG*` domain model the rest of Pidgy consumes. Slack's string ids are
/// turned into synthetic `Int64`s via `DatabaseManager`'s `id_map`, stamped
/// with `SourceID(kind: .slack, account: teamId)` so multiple workspaces stay
/// distinct.
///
/// Read-only v1: no sending, no unread counts, no media — those map to
/// defaults until the domain model grows source-neutral fields.
@MainActor
final class SlackService: ObservableObject, MessageSource {
    nonisolated let sourceID: SourceID

    @Published private(set) var chats: [TGChat] = []
    @Published private(set) var currentUser: TGUser?
    @Published private(set) var isLoaded = false

    private let clientId: String
    private var accessToken: String
    private var refreshToken: String?
    private var tokenExpiry: Date?
    private let teamName: String?
    private let authedUserNativeId: String
    private let api: SlackAPIClient
    private let db: DatabaseManager

    /// native Slack id ("U…"/"C…") → synthetic Int64, cached to avoid
    /// re-hitting the id_map on every message map.
    private var idCache: [String: Int64] = [:]
    private var userCache: [String: TGUser] = [:]
    /// Thread roots already hydrated this session (keyed by native id) so each
    /// thread costs at most one `conversations.replies` paging pass per launch.
    private var hydratedThreadRoots: Set<String> = []
    /// Dedupes concurrent token refreshes. Slack rotates the refresh token on
    /// every use, so two refreshes racing would each invalidate the other's
    /// token and lock the workspace out until a full re-OAuth.
    private var refreshInFlight: Task<Void, Never>?

    /// The dedicated background freshness+depth loop; cancelled on disconnect.
    private var refreshLoopTask: Task<Void, Never>?
    /// Chats already breadth-fetched this session (so a genuinely-empty channel
    /// isn't re-polled every tick). Only set on a *successful* first fetch, so a
    /// transient failure still retries.
    private var breadthAttempted: Set<Int64> = []
    /// Chats deepened to `depthTargetPerChat` (or with no older history left) —
    /// skipped by the Stage-2 depth backfill.
    private var fullyDeepened: Set<Int64> = []
    /// Freshness/breadth slots spent since the last depth slot — drives the
    /// depth reservation in `selectNextTarget`.
    private var ticksSinceDepth = 0

    /// Hard caps so a huge workspace / a malformed-or-looping cursor can't spin
    /// a `while cursor` loop forever or accumulate unbounded remote-sized data.
    private static let maxPaginationPages = 50
    private static let maxWarmedUsers = 2_000
    private static let maxIdCacheEntries = 20_000
    private static let maxHydratedThreadRoots = 1_000
    /// Replies are rate-limited (~1/min); cap on-demand thread paging so a
    /// giant thread can't stall the panel for many minutes.
    private static let maxReplyPages = 4

    // MARK: Background refresh-loop tuning
    //
    // `conversations.history` is paced to ~1/min by `SlackRateLimiter`, so the
    // loop's hard ceiling is one chat per ~minute regardless. These knobs only
    // decide *which* chat each scarce slot is spent on, and when to idle.

    /// Slack's hard per-request object cap on the non-Marketplace tier — one
    /// `history` call can never return more than this many messages.
    private static let slackPageSize = 15
    /// Extra spacing on top of the rate limiter so the loop doesn't permanently
    /// saturate the shared `history` bucket — leaves a window for interactive
    /// chat opens to slip a fetch in.
    private static let refreshHeadroomSeconds: UInt64 = 12
    /// Sleep when nothing is due (everything fresh and fully deepened).
    private static let refreshIdleSeconds: UInt64 = 45
    /// Freshness windows by activity: a chat becomes "due" for a new-message
    /// poll once this long has elapsed since its last sync. Active chats poll
    /// often, dormant ones rarely — so the 1/min budget favors what's moving.
    private static let freshWindowActive: TimeInterval = 5 * 60     // last activity < 1 day
    private static let freshWindowWarm: TimeInterval = 20 * 60      // < 1 week
    private static let freshWindowCold: TimeInterval = 60 * 60      // older / unknown
    /// Stage 2 depth backfill: page older history (≤15/min) until a chat has at
    /// least this many cached messages, then stop deepening it.
    private static let depthTargetPerChat = 100
    /// Reserve 1 slot for depth after this many freshness/breadth slots, so a
    /// steady stream of active-chat freshness can't starve history backfill
    /// (without it, depth only runs when the whole workspace goes quiet).
    private static let depthEveryNTicks = 4

    init(
        clientId: String,
        teamId: String,
        teamName: String?,
        authedUserNativeId: String,
        accessToken: String,
        refreshToken: String? = nil,
        tokenExpiry: Date? = nil,
        api: SlackAPIClient = SlackAPIClient(),
        db: DatabaseManager = .shared
    ) {
        self.sourceID = SourceID(kind: .slack, account: teamId)
        self.clientId = clientId
        self.teamName = teamName
        self.authedUserNativeId = authedUserNativeId
        self.api = api
        self.db = db
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenExpiry = tokenExpiry
    }

    /// Set the token on the API client and do the first conversation load.
    /// Called once after registration so reads never race ahead of auth.
    func start() async {
        await api.setAccessToken(accessToken)
        await ensureValidToken()
        await warmUserCache()
        await loadConversations()
        await reformatCachedSlackText()
        startRefreshLoop()
    }

    /// Bulk-load workspace members once so message-mention decoding resolves
    /// names from cache instead of a per-mention `users.info` lookup (which
    /// rate-limits hard). Paginated; tolerant of partial failure.
    private func warmUserCache() async {
        var cursor: String?
        var pages = 0
        repeat {
            guard let page = try? await api.usersList(cursor: cursor) else { break }
            for user in page.members ?? [] where userCache[user.id] == nil {
                guard userCache.count < Self.maxWarmedUsers else { break }
                guard let id = await mintId(user.id) else { continue }
                let displayName = user.profile?.displayName?.nilIfEmpty
                    ?? user.realName
                    ?? user.name
                    ?? "Unknown"
                userCache[user.id] = TGUser(
                    id: id,
                    firstName: displayName,
                    lastName: "",
                    username: user.name,
                    phoneNumber: nil,
                    isBot: user.isBot ?? false,
                    smallPhotoFileId: nil,
                    avatarURL: user.profile?.image72
                )
            }
            cursor = page.responseMetadata?.nextCursor
            pages += 1
        } while !(cursor ?? "").isEmpty && pages < Self.maxPaginationPages && userCache.count < Self.maxWarmedUsers
    }

    /// One-time pass to decode Slack markup in already-cached message text
    /// (mentions/links/channels) so previously-synced conversations show
    /// readable text without waiting for a re-fetch. Only touches chats that
    /// actually have unresolved `<…>` tokens.
    func reformatCachedSlackText() async {
        for chat in chats where chat.isInMainList {
            let records = await db.loadMessages(chatId: chat.id, limit: 200)
            guard records.contains(where: { ($0.textContent ?? "").contains("<") }) else { continue }
            var updated: [TGMessage] = []
            for record in records {
                let message = MessageCacheService.CachedMessage.from(record).toTGMessage()
                updated.append(message.updating(textContent: formatSlackText(message.textContent)))
            }
            await MessageCacheService.shared.cacheMessages(chatId: chat.id, messages: updated)
        }
    }

    /// Refresh the access token if rotation is on and it's near expiry.
    /// No-op when there's no expiry (long-lived token) or no refresh token.
    private func ensureValidToken() async {
        guard refreshToken != nil else { return }
        // Still comfortably valid? nothing to do.
        if let expiry = tokenExpiry, Date() < expiry.addingTimeInterval(-60) { return }
        // Single-flight: if a refresh is already running, await it instead of
        // starting a second one. Concurrent refreshes each rotate (and thereby
        // invalidate) the other's `xoxe` refresh token, which locks the
        // workspace out until a manual reconnect.
        if let inFlight = refreshInFlight {
            await inFlight.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performTokenRefresh()
        }
        refreshInFlight = task
        await task.value
        refreshInFlight = nil
    }

    /// The actual refresh, only ever run one-at-a-time via `ensureValidToken`'s
    /// single-flight. Refreshes when the expiry is unknown (connected before
    /// rotation handling) or near lapse; `xoxe` access tokens always rotate so
    /// an unknown expiry can't be trusted.
    private func performTokenRefresh() async {
        guard let refresh = refreshToken else { return }
        // A refresh that finished while we were queued may have already renewed.
        if let expiry = tokenExpiry, Date() < expiry.addingTimeInterval(-60) { return }
        guard let access = try? await api.refreshToken(clientId: clientId, refreshToken: refresh),
              let newToken = access.userAccessToken else { return }
        accessToken = newToken
        await api.setAccessToken(newToken)
        try? KeychainManager.save(newToken, for: .slackAccessToken)
        if let newRefresh = access.userRefreshToken {
            refreshToken = newRefresh
            try? KeychainManager.save(newRefresh, for: .slackRefreshToken)
        }
        if let expiresIn = access.userExpiresIn {
            let newExpiry = Date().addingTimeInterval(TimeInterval(expiresIn))
            tokenExpiry = newExpiry
            try? KeychainManager.save(String(newExpiry.timeIntervalSince1970), for: .slackTokenExpiry)
        }
    }

    // MARK: - MessageSource

    var visibleChats: [TGChat] { chats.filter { $0.isInMainList } }

    /// Token present means we can answer reads. Chats populate asynchronously.
    var isReady: Bool { isLoaded }

    func chatHistory(chatId: Int64, fromMessageId: Int64, limit: Int) async throws -> [TGMessage] {
        await ensureValidToken()
        guard let channelNative = try await db.nativeId(source: sourceID, intId: chatId) else { return [] }

        // `fromMessageId` (a synthetic id) → its ts → Slack's `latest` cursor
        // so we page strictly older, matching the Telegram contract.
        var latest: String?
        if fromMessageId != 0,
           let raw = try await db.nativeId(source: sourceID, intId: fromMessageId) {
            latest = Self.ts(fromMessageNative: raw)
        }

        let history = try await api.conversationsHistory(
            channel: channelNative,
            latest: latest,
            limit: min(limit, 15)
        )
        var mapped: [TGMessage] = []
        for message in history.messages ?? [] {
            if let tg = await mapMessage(message, channelNative: channelNative, channelId: chatId, channelTitle: nil) {
                mapped.append(tg)
            }
        }
        return mapped
    }

    /// Fetch the thread that `messageId` belongs to (Slack returns replies only
    /// via `conversations.replies`, never in channel history), cache it, and
    /// return parent + replies. Deduped to one network call per thread root per
    /// session; called on demand when an evidence panel for a Slack message opens.
    func hydrateThread(messageId: Int64, threadRootId: Int64?) async -> [TGMessage] {
        await ensureValidToken()
        // The thread is keyed by its parent; if the source is a reply we already
        // know the parent's synthetic id, otherwise the message is its own root.
        let rootId = threadRootId ?? messageId
        guard let rootNative = try? await db.nativeId(source: sourceID, intId: rootId),
              let (channelNative, rootTs) = Self.parseMessageNative(rootNative) else { return [] }
        // Skip only if we already paged this thread to completion this session.
        guard !hydratedThreadRoots.contains(rootNative) else { return [] }
        guard let channelId = await mintId(channelNative) else { return [] }

        // Page through replies (each page is rate-limited ~1/min) up to a cap so
        // a giant thread can't stall the panel — but no longer truncate at 30.
        var mapped: [TGMessage] = []
        var cursor: String?
        var pages = 0
        var reachedEnd = false
        repeat {
            guard let history = try? await api.conversationsReplies(channel: channelNative, ts: rootTs, cursor: cursor) else { break }
            for message in history.messages ?? [] {
                if let tg = await mapMessage(message, channelNative: channelNative, channelId: channelId, channelTitle: nil) {
                    mapped.append(tg)
                }
            }
            cursor = history.responseMetadata?.nextCursor
            pages += 1
            if (cursor ?? "").isEmpty { reachedEnd = true }
        } while !(cursor ?? "").isEmpty && pages < Self.maxReplyPages

        // Mark fully hydrated only once we've paged to the end, so a partial
        // fetch (rate-limit / cap hit) can be retried on a later open.
        if reachedEnd {
            if hydratedThreadRoots.count >= Self.maxHydratedThreadRoots {
                hydratedThreadRoots.removeAll(keepingCapacity: true)
            }
            hydratedThreadRoots.insert(rootNative)
        }
        guard !mapped.isEmpty else { return [] }
        // Merge (append: true) so we add the thread to the channel's cache
        // instead of clobbering its already-cached history with just replies.
        await MessageCacheService.shared.cacheMessages(chatId: channelId, messages: mapped, append: true)
        return mapped
    }

    /// "msg:<channel>:<ts>" → (channel, ts). Slack channel ids and message
    /// timestamps contain no ":", so a 3-way split is unambiguous.
    private static func parseMessageNative(_ native: String) -> (channel: String, ts: String)? {
        let parts = native.components(separatedBy: ":")
        guard parts.count == 3, parts[0] == "msg" else { return nil }
        return (parts[1], parts[2])
    }

    func user(id: Int64) async throws -> TGUser? {
        await ensureValidToken()
        guard let native = try await db.nativeId(source: sourceID, intId: id) else { return nil }
        return await resolveUser(nativeId: native)
    }

    nonisolated func isLikelyBot(chat: TGChat) -> Bool { false }

    // MARK: - Loading

    /// Pull the workspace's conversations and publish them as `TGChat`s.
    /// Called by the sync layer; safe to call repeatedly.
    func loadConversations() async {
        await ensureValidToken()
        if currentUser == nil {
            currentUser = await resolveUser(nativeId: authedUserNativeId)
        }

        var collected: [TGChat] = []
        var cursor: String?
        var pages = 0
        var pageError = false
        repeat {
            do {
                let page = try await api.conversationsList(cursor: cursor)
                for conversation in page.channels ?? [] {
                    if let chat = await mapConversation(conversation) {
                        collected.append(chat)
                    }
                }
                cursor = page.responseMetadata?.nextCursor
            } catch {
                pageError = true
                break
            }
            pages += 1
        } while !(cursor ?? "").isEmpty && pages < Self.maxPaginationPages

        // A mid-pagination failure leaves `collected` partial. Don't replace an
        // already-published (fuller) chat list with a truncated one on a
        // transient error — keep what we have and let the next pass retry.
        if pageError && collected.count < chats.count { return }

        // Enrich each chat with its latest already-cached message so it shows
        // a preview/timestamp and sorts by recency immediately, instead of
        // waiting for the paced sync to re-fetch every channel.
        var enriched: [TGChat] = []
        for chat in collected {
            if let record = await db.loadMessages(chatId: chat.id, limit: 1).first {
                let latest = MessageCacheService.CachedMessage.from(record).toTGMessage()
                enriched.append(chat.updating(lastMessage: latest))
            } else {
                enriched.append(chat)
            }
        }

        chats = enriched
        // Ready on a clean load, or a partial-but-non-empty one (a rate-limited
        // workspace still shows what it can); a totally failed first load stays
        // not-ready so the next sync pass retries.
        if !pageError || !enriched.isEmpty {
            isLoaded = true
        }
    }

    // MARK: - Background refresh loop

    /// Start the dedicated Slack freshness+depth loop. Replaces riding inside
    /// `RecentSyncCoordinator`'s Telegram batches, where one Slack chat's ~60s
    /// rate-limit slot stalled the three Telegram chats sharing its batch. Now
    /// one Slack chat is refreshed per paced slot, chosen by what's most worth
    /// spending the scarce budget on.
    func startRefreshLoop() {
        guard refreshLoopTask == nil else { return }
        refreshLoopTask = Task { [weak self] in
            await self?.refreshLoop()
        }
    }

    /// Stop the loop (disconnect / replace). Safe to call repeatedly.
    func shutdown() {
        refreshLoopTask?.cancel()
        refreshLoopTask = nil
    }

    private func refreshLoop() async {
        while !Task.isCancelled {
            guard let target = await selectNextTarget() else {
                // Nothing due and nothing left to deepen — idle briefly.
                try? await Task.sleep(for: .seconds(Self.refreshIdleSeconds))
                continue
            }

            switch target {
            case .freshen(let chat): await refreshNewest(chat)
            case .deepen(let chat): await backfillOlder(chat)
            }
            if Task.isCancelled { return }

            // The history call already blocked ~60s on the rate limiter; a small
            // extra gap keeps the loop from permanently owning the shared bucket
            // so an interactive chat-open can still slip a fetch through.
            try? await Task.sleep(for: .seconds(Self.refreshHeadroomSeconds))
        }
    }

    private enum RefreshTarget {
        case freshen(TGChat)   // poll for messages newer than what's cached (or the first fetch)
        case deepen(TGChat)    // Stage 2: page older history toward the depth target
    }

    /// Choose which chat the next paced slot is spent on. Freshness leads, but
    /// roughly 1 slot in `depthEveryNTicks + 1` is reserved for depth so steady
    /// active-chat freshness can't starve history backfill. Within each, most
    /// recently active first.
    /// • (reserved) deepen an active chat below the depth target,
    /// • freshen a content chat past its activity-scaled window,
    /// • seed a never-fetched chat (breadth),
    /// • else deepen whatever backfill remains.
    private func selectNextTarget() async -> RefreshTarget? {
        let slackChats = chats.filter { $0.isInMainList }
        guard !slackChats.isEmpty else { return nil }

        let withContent = slackChats.filter { $0.lastMessage != nil }
        let states = withContent.isEmpty ? [:] : await db.loadRecentSyncStates(in: withContent.map(\.id))
        let now = Date()

        let dueChat = withContent
            .filter { chat in
                guard let at = states[chat.id]?.lastRecentSyncAt else { return true }
                return now.timeIntervalSince(at) >= freshnessWindow(for: chat)
            }
            .max(by: { ($0.lastActivityDate ?? .distantPast) < ($1.lastActivityDate ?? .distantPast) })

        let breadthChat = slackChats.first(where: { $0.lastMessage == nil && !breadthAttempted.contains($0.id) })

        let deepenChat = withContent
            .filter { !fullyDeepened.contains($0.id) }
            .max(by: { ($0.lastActivityDate ?? .distantPast) < ($1.lastActivityDate ?? .distantPast) })

        // Reserved depth slot: only when freshness/breadth work is actually
        // competing for the budget (otherwise depth runs freely below).
        if let deepenChat, (dueChat != nil || breadthChat != nil), ticksSinceDepth >= Self.depthEveryNTicks {
            ticksSinceDepth = 0
            return .deepen(deepenChat)
        }

        // 1) Freshness, 2) breadth — each counts toward the next reserved slot.
        if let dueChat { ticksSinceDepth += 1; return .freshen(dueChat) }
        if let breadthChat { ticksSinceDepth += 1; return .freshen(breadthChat) }

        // 3) Depth, unconstrained when there's no freshness work left to do.
        if let deepenChat { ticksSinceDepth = 0; return .deepen(deepenChat) }

        return nil
    }

    /// Shorter freshness window for recently-active chats, so the scarce budget
    /// keeps live conversations current and barely touches dormant ones.
    private func freshnessWindow(for chat: TGChat) -> TimeInterval {
        guard let last = chat.lastActivityDate else { return Self.freshWindowCold }
        let age = Date().timeIntervalSince(last)
        if age < 24 * 60 * 60 { return Self.freshWindowActive }
        if age < 7 * 24 * 60 * 60 { return Self.freshWindowWarm }
        return Self.freshWindowCold
    }

    /// Pull messages newer than the newest cached one (incremental, so the slot
    /// isn't wasted re-fetching the same 15), or the latest page for a chat with
    /// nothing cached. Caches, updates the preview, records sync state, and
    /// notifies downstream indexers.
    ///
    /// Note: a single page is capped at 15 by Slack, so a firehose channel that
    /// produced >15 messages within one freshness window keeps only the newest
    /// 15 of that burst (older-but-unseen middle is left to Stage-2 depth). That
    /// trade favors recent activity — what the reply queue cares about — over
    /// perfect continuity on high-velocity channels, within the 1/min budget.
    private func refreshNewest(_ chat: TGChat) async {
        let cachedNewest = await db.loadMessages(chatId: chat.id, limit: 1).first
        var messages: [TGMessage] = []
        if let cachedNewest,
           let native = try? await db.nativeId(source: sourceID, intId: cachedNewest.id),
           let ts = Self.ts(fromMessageNative: native) {
            messages = (try? await fetchHistory(chat: chat, oldest: ts)) ?? []
        } else {
            // First fetch. Distinguish a successful-but-empty channel (mark done,
            // don't re-poll) from a transient failure (leave for retry).
            do {
                messages = try await fetchHistory(chat: chat, oldest: nil)
                breadthAttempted.insert(chat.id)
            } catch {
                return
            }
        }

        if !messages.isEmpty {
            await MessageCacheService.shared.cacheMessages(chatId: chat.id, messages: messages, append: true)
            if let newest = messages.max(by: { $0.date < $1.date }),
               let index = chats.firstIndex(where: { $0.id == chat.id }) {
                chats[index] = chats[index].updating(lastMessage: newest)
            }
            postLocalUpdate(chatId: chat.id, count: messages.count)
        }

        // Record the poll even on no yield, so an idle chat isn't re-polled until
        // its freshness window lapses again.
        let latestId = messages.max(by: { $0.date < $1.date })?.id
            ?? cachedNewest?.id
            ?? chat.lastMessage?.id
            ?? 0
        if latestId != 0 {
            await db.saveRecentSyncState(chatId: chat.id, latestSyncedMessageId: latestId, syncedAt: Date())
        }
    }

    /// Stage 2: page one window of history *older* than the oldest cached
    /// message, until the chat reaches the depth target or runs out of history.
    private func backfillOlder(_ chat: TGChat) async {
        let cached = await db.loadMessages(chatId: chat.id, limit: Self.depthTargetPerChat)
        guard cached.count < Self.depthTargetPerChat, let oldest = cached.last else {
            fullyDeepened.insert(chat.id)   // already deep enough
            return
        }
        let older = (try? await chatHistory(chatId: chat.id, fromMessageId: oldest.id, limit: Self.slackPageSize)) ?? []
        guard !older.isEmpty else {
            fullyDeepened.insert(chat.id)   // no older history left
            return
        }
        await MessageCacheService.shared.cacheMessages(chatId: chat.id, messages: older, append: true)
        postLocalUpdate(chatId: chat.id, count: older.count)
    }

    /// One `conversations.history` page. With `oldest` set, returns messages
    /// strictly newer than it (incremental poll); without, the latest page.
    private func fetchHistory(chat: TGChat, oldest: String?) async throws -> [TGMessage] {
        await ensureValidToken()
        guard let channelNative = try await db.nativeId(source: sourceID, intId: chat.id) else { return [] }
        let history = try await api.conversationsHistory(
            channel: channelNative,
            oldest: oldest,
            limit: Self.slackPageSize
        )
        var mapped: [TGMessage] = []
        for message in history.messages ?? [] {
            if let tg = await mapMessage(message, channelNative: channelNative, channelId: chat.id, channelTitle: nil) {
                mapped.append(tg)
            }
        }
        return mapped
    }

    /// Tell downstream consumers (TaskIndex, GraphBuilder, search) that fresh
    /// Slack messages just landed — the same signal `RecentSyncCoordinator`
    /// posts for Telegram, which Slack no longer rides inside.
    private func postLocalUpdate(chatId: Int64, count: Int) {
        guard count > 0 else { return }
        NotificationCenter.default.post(
            name: .pidgyMessagesUpdatedLocally,
            object: nil,
            userInfo: ["chatIds": [chatId], "messageCount": count]
        )
    }

    // MARK: - Mapping

    private func mapConversation(_ conversation: SlackConversation) async -> TGChat? {
        guard let id = await mintId(conversation.id) else { return nil }

        let chatType: TGChat.ChatType
        if conversation.isIm == true {
            let otherUserId = conversation.user.flatMap { native in idCache[native] } ?? id
            chatType = .privateChat(userId: otherUserId)
        } else if conversation.isMpim == true {
            chatType = .basicGroup(groupId: id)
        } else {
            // Public/private channels behave like participatory supergroups,
            // not broadcast channels.
            chatType = .supergroup(supergroupId: id, isChannel: false)
        }

        var title = conversation.name ?? "Conversation"
        var avatarURL: String?
        if conversation.isIm == true, let native = conversation.user {
            let user = await resolveUser(nativeId: native)
            title = user?.displayName ?? title
            avatarURL = user?.avatarURL
        } else if conversation.isMpim != true, let name = conversation.name {
            // Public/private channels read as "#name" (Slack convention);
            // group DMs (mpim) keep their generated name.
            title = "#\(name)"
        }

        return TGChat(
            id: id,
            title: title,
            chatType: chatType,
            unreadCount: 0,
            lastMessage: nil,
            memberCount: conversation.numMembers,
            order: 0,
            isInMainList: conversation.isArchived != true,
            smallPhotoFileId: nil,
            source: sourceID,
            avatarURL: avatarURL
        )
    }

    private func mapMessage(
        _ message: SlackMessage,
        channelNative: String,
        channelId: Int64,
        channelTitle: String?
    ) async -> TGMessage? {
        guard let id = await mintId("msg:\(channelNative):\(message.ts)") else { return nil }

        let sender: TGMessage.MessageSenderId
        var senderName: String?
        if let userNative = message.user {
            if let userId = await mintId(userNative) {
                sender = .user(userId)
            } else {
                sender = .chat(channelId)
            }
            senderName = await resolveUser(nativeId: userNative)?.displayName
        } else {
            sender = .chat(channelId)
        }

        let date = Self.ts(fromMessageNative: message.ts).flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
            ?? Date(timeIntervalSince1970: Double(message.ts) ?? 0)

        // A `thread_ts` that differs from this message's own `ts` means it's a
        // reply hanging off a parent; point it at the parent's synthetic id so
        // the evidence panel can nest it. When they're equal this *is* the root.
        var threadRootId: Int64?
        if let threadTs = message.threadTs, threadTs != message.ts {
            threadRootId = await mintId("msg:\(channelNative):\(threadTs)")
        }

        return TGMessage(
            id: id,
            chatId: channelId,
            senderId: sender,
            date: date,
            textContent: formatSlackText(message.text),
            mediaType: nil,
            isOutgoing: message.user == authedUserNativeId,
            chatTitle: channelTitle,
            senderName: senderName,
            source: sourceID,
            threadRootId: threadRootId
        )
    }

    /// Decode Slack's message markup into readable text: `<@U…>` → `@Name`,
    /// `<#C…|name>` → `#name`, `<!here>` → `@here`, and `<url|label>` → `label`
    /// (or the bare url). Slack also HTML-escapes `& < >`, which we unescape.
    private func formatSlackText(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return raw }
        var output = ""
        var cursor = raw.startIndex
        for match in raw.matches(of: /<([^>]+)>/) {
            output += String(raw[cursor..<match.range.lowerBound])
            output += expandSlackToken(String(match.output.1))
            cursor = match.range.upperBound
        }
        output += String(raw[cursor...])
        return output
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    private func expandSlackToken(_ token: String) -> String {
        let segments = token.split(separator: "|", maxSplits: 1).map(String.init)
        guard let head = segments.first, !head.isEmpty else { return token }
        let label = segments.count > 1 ? segments[1] : nil

        if head.hasPrefix("@") {                       // user mention (cache-only)
            let userId = String(head.dropFirst())
            if let name = userCache[userId]?.displayName { return "@\(name)" }
            return "@" + (label ?? userId)
        }
        if head.hasPrefix("#") {                       // channel mention
            return "#" + (label ?? "channel")
        }
        if head.hasPrefix("!") {                       // @here / @channel / etc.
            switch String(head.dropFirst()) {
            case "here": return "@here"
            case "channel": return "@channel"
            case "everyone": return "@everyone"
            default: return label ?? ("@" + String(head.dropFirst()))
            }
        }
        return label ?? head                           // <url> or <url|label>
    }

    private func resolveUser(nativeId: String) async -> TGUser? {
        if let cached = userCache[nativeId] { return cached }
        guard let id = await mintId(nativeId) else { return nil }
        guard let response = try? await api.usersInfo(user: nativeId), let user = response.user else { return nil }

        let displayName = user.profile?.displayName?.nilIfEmpty
            ?? user.realName
            ?? user.name
            ?? "Unknown"
        let tgUser = TGUser(
            id: id,
            firstName: displayName,
            lastName: "",
            username: user.name,
            phoneNumber: nil,
            isBot: user.isBot ?? false,
            smallPhotoFileId: nil,
            avatarURL: user.profile?.image72
        )
        userCache[nativeId] = tgUser
        return tgUser
    }

    /// Mint (or look up) the synthetic id for a native Slack id, memoized.
    private func mintId(_ nativeId: String) async -> Int64? {
        if let cached = idCache[nativeId] { return cached }
        guard let id = try? await db.mintId(source: sourceID, nativeId: nativeId) else { return nil }
        // Bounded: this is a pure lookup cache — evicting just means the next
        // miss re-reads the persistent id_map (same id back), no correctness hit.
        if idCache.count >= Self.maxIdCacheEntries { idCache.removeAll(keepingCapacity: true) }
        idCache[nativeId] = id
        return id
    }

    /// Recover the Slack ts from a message native id ("msg:C…:<ts>").
    private static func ts(fromMessageNative native: String) -> String? {
        guard native.hasPrefix("msg:") else { return native }
        return native.split(separator: ":").last.map(String.init)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
