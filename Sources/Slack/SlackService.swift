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
        await syncRecentMessages()
    }

    /// Bulk-load workspace members once so message-mention decoding resolves
    /// names from cache instead of a per-mention `users.info` lookup (which
    /// rate-limits hard). Paginated; tolerant of partial failure.
    private func warmUserCache() async {
        var cursor: String?
        repeat {
            guard let page = try? await api.usersList(cursor: cursor) else { break }
            for user in page.members ?? [] where userCache[user.id] == nil {
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
        } while !(cursor ?? "").isEmpty
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
        guard let refresh = refreshToken else { return }
        // Refresh when the expiry is unknown (connected before rotation
        // handling → no stored expiry) or within 60s of lapsing. `xoxe`
        // access tokens always rotate, so an unknown expiry can't be trusted.
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
                break
            }
        } while !(cursor ?? "").isEmpty

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
        isLoaded = true
    }

    /// Proactively cache recent history per channel so Slack messages flow
    /// into search / reply queue / tasks without the user opening each chat.
    /// Paced ~1 channel/min to respect Slack's non-Marketplace
    /// `conversations.history` limit; browsing caches on demand separately.
    func syncRecentMessages(perChannelLimit: Int = 15) async {
        // Only spend rate budget on channels we don't already have cached —
        // the on-load enrichment surfaces the rest instantly. Across launches
        // this covers the whole workspace without re-fetching what we have.
        let pending = chats.filter { $0.isInMainList && $0.lastMessage == nil }
        for chat in pending {
            if let messages = try? await chatHistory(chatId: chat.id, fromMessageId: 0, limit: perChannelLimit),
               !messages.isEmpty {
                await MessageCacheService.shared.cacheMessages(chatId: chat.id, messages: messages)
                // Attach the newest message so the chat shows a preview /
                // timestamp and sorts by recency instead of sinking to the
                // bottom of the unified list.
                if let newest = messages.max(by: { $0.date < $1.date }),
                   let index = chats.firstIndex(where: { $0.id == chat.id }) {
                    chats[index] = chats[index].updating(lastMessage: newest)
                }
            }
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
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
            source: sourceID
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
