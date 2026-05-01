import Foundation
import TDLibKit

/// Central service for all Telegram operations.
/// Read-only by design — no write/send/modify methods exist.
@MainActor
class TelegramService: ObservableObject {
    struct LocalMessageSearchHit: Sendable {
        let message: TGMessage
        let score: Double
    }

    @Published var authState: AuthState = .uninitialized
    @Published var connectionState: ConnectionState = .connectionStateConnecting
    @Published var chats: [TGChat] = []
    @Published var currentUser: TGUser?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var botMetadataRefreshVersion = 0

    private let tdClient = TDLibClientWrapper()
    private let rateLimiter = RateLimiter()
    private var updateTask: Task<Void, Never>?
    private var chatDiscoveryTask: Task<Void, Never>?
    private var botMetadataWarmTask: Task<Void, Never>?
    private var userCache: [Int64: TGUser] = [:]
    private var chatCache: [Int64: TGChat] = [:]

    /// The underlying TDLibKit client for direct API calls
    private var client: TDLibKit.TDLibClient? {
        tdClient.client
    }

    // MARK: - Lifecycle

    func start(apiId: Int, apiHash: String) {
        updateTask?.cancel()
        updateTask = nil
        chatDiscoveryTask?.cancel()
        chatDiscoveryTask = nil
        botMetadataWarmTask?.cancel()
        botMetadataWarmTask = nil

        tdClient.start(apiId: apiId, apiHash: apiHash)
        startListeningForUpdates()

        // Set TDLib parameters
        Task {
            try? await setTdlibParameters(apiId: apiId, apiHash: apiHash)
        }
    }

    func stop() {
        updateTask?.cancel()
        updateTask = nil
        chatDiscoveryTask?.cancel()
        chatDiscoveryTask = nil
        botMetadataWarmTask?.cancel()
        botMetadataWarmTask = nil
        tdClient.close()
    }

    private func startListeningForUpdates() {
        updateTask = Task { [weak self] in
            guard let self else { return }
            for await update in self.tdClient.updates {
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    self.handleUpdate(update)
                }
            }
        }
    }

    // MARK: - TDLib Parameters

    private func setTdlibParameters(apiId: Int, apiHash: String) async throws {
        guard let client else { throw TGError.clientNotInitialized }

        let dbPath = TDLibClientWrapper.databasePath()

        _ = try await client.setTdlibParameters(
            apiHash: apiHash,
            apiId: apiId,
            applicationVersion: AppConstants.App.version,
            databaseDirectory: dbPath,
            databaseEncryptionKey: Data(),
            deviceModel: "macOS",
            filesDirectory: dbPath + "/files",
            systemLanguageCode: "en-US",
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            useChatInfoDatabase: true,
            useFileDatabase: true,
            useMessageDatabase: true,
            useSecretChats: false,
            useTestDc: false
        )
    }

    // MARK: - Authentication (read-only; these are required to establish a session)

    func setPhoneNumber(_ phone: String) async throws {
        guard let client else { throw TGError.clientNotInitialized }
        // Strip spaces, dashes, and parentheses from phone number
        let cleanPhone = phone.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
        _ = try await client.setAuthenticationPhoneNumber(
            phoneNumber: cleanPhone,
            settings: nil
        )
    }

    func submitVerificationCode(_ code: String) async throws {
        guard let client else { throw TGError.clientNotInitialized }
        _ = try await client.checkAuthenticationCode(code: code)
    }

    func submitPassword(_ password: String) async throws {
        guard let client else { throw TGError.clientNotInitialized }
        _ = try await client.checkAuthenticationPassword(password: password)
    }

    func requestQrCodeAuth() async throws {
        guard let client else { throw TGError.clientNotInitialized }
        _ = try await client.requestQrCodeAuthentication(otherUserIds: [])
    }

    func logOut() async throws {
        guard let client else { throw TGError.clientNotInitialized }
        _ = try await client.logOut()
    }

    // MARK: - Chat Operations (read-only)

    func loadChats(
        limit: Int = AppConstants.Fetch.chatListLimit,
        priority: RateLimiter.Priority = .userInitiated,
        updatesLoadingState: Bool = true
    ) async throws {
        if updatesLoadingState {
            isLoading = true
        }
        defer {
            if updatesLoadingState {
                isLoading = false
            }
        }

        _ = try await withRateLimitedCall(priority: priority, method: "loadChats") { client in
            try await client.loadChats(chatList: .chatListMain, limit: limit)
        }
        // Chats arrive via updateNewChat updates
    }

    private func startBackgroundChatDiscovery() {
        chatDiscoveryTask?.cancel()
        chatDiscoveryTask = Task { [weak self] in
            guard let self else { return }
            await self.discoverAdditionalMainListChats()
        }
    }

    private func discoverAdditionalMainListChats() async {
        var stagnantPasses = 0
        var lastVisibleCount = visibleChats.count

        while !Task.isCancelled && stagnantPasses < AppConstants.Fetch.maxStagnantBackgroundChatDiscoveryPasses {
            do {
                try await loadChats(
                    limit: AppConstants.Fetch.backgroundChatDiscoveryLimit,
                    priority: .background,
                    updatesLoadingState: false
                )
            } catch let error as TDLibKit.Error {
                if isMainChatListExhausted(error) {
                    return
                }

                print("[TelegramService] Background chat discovery stopped: \(error.code) \(error.message)")
                return
            } catch {
                print("[TelegramService] Background chat discovery stopped: \(error.localizedDescription)")
                return
            }

            try? await Task.sleep(
                for: .milliseconds(Int(AppConstants.Fetch.backgroundChatDiscoverySettleDelayMilliseconds))
            )

            let currentVisibleCount = visibleChats.count
            if currentVisibleCount > lastVisibleCount {
                lastVisibleCount = currentVisibleCount
                stagnantPasses = 0
            } else {
                stagnantPasses += 1
            }

            try? await Task.sleep(
                for: .milliseconds(Int(AppConstants.Fetch.backgroundChatDiscoveryInterPassDelayMilliseconds))
            )
        }
    }

    private func isMainChatListExhausted(_ error: TDLibKit.Error) -> Bool {
        error.code == 404
    }

    private func normalizedMemberCount(_ memberCount: Int?) -> Int? {
        guard let memberCount, memberCount > 0 else { return nil }
        return memberCount
    }

    func getChat(id: Int64) async throws -> TGChat? {
        if let cached = chatCache[id] { return cached }

        let chat = try await withRateLimitedCall(method: "getChat") { client in
            try await client.getChat(chatId: id)
        }
        let tgChat = mapChat(chat)
        chatCache[tgChat.id] = tgChat
        return tgChat
    }

    func resolvedMemberCount(for chat: TGChat) async -> Int? {
        if let cached = normalizedMemberCount(chat.memberCount) {
            return cached
        }

        let fetchedCount: Int?
        switch chat.chatType {
        case .basicGroup(let groupId):
            fetchedCount = await fetchBasicGroupMemberCount(groupId: groupId)
        case .supergroup(let supergroupId, _):
            fetchedCount = await fetchSupergroupMemberCount(supergroupId: supergroupId)
        case .privateChat, .secretChat:
            fetchedCount = nil
        }

        guard let fetchedCount else { return nil }
        cacheMemberCount(fetchedCount, for: chat.id)
        return fetchedCount
    }

    // MARK: - File Downloads (read-only)

    /// Download a file by ID and return the local path once complete.
    func downloadFile(fileId: Int) async throws -> String {
        guard let client else { throw TGError.clientNotInitialized }
        let file = try await client.downloadFile(
            fileId: fileId,
            limit: 0,
            offset: 0,
            priority: 16,
            synchronous: true
        )
        return file.local.path
    }

    // MARK: - Message History (read-only)

    func getChatHistory(
        chatId: Int64,
        fromMessageId: Int64 = 0,
        limit: Int = 50,
        onlyLocal: Bool = false,
        priority: RateLimiter.Priority = .userInitiated
    ) async throws -> [TGMessage] {
        let result = try await withRateLimitedCall(priority: priority, method: "getChatHistory") { client in
            try await client.getChatHistory(
                chatId: chatId,
                fromMessageId: fromMessageId,
                limit: limit,
                offset: 0,
                onlyLocal: onlyLocal
            )
        }

        return (result.messages ?? []).compactMap { mapMessage($0) }
    }

    // MARK: - Search (read-only)

    func searchMessages(
        query: String,
        limit: Int = 50,
        chatTypeFilter: SearchMessagesChatTypeFilter? = nil
    ) async throws -> [TGMessage] {
        guard !query.isEmpty else { return [] }
        let result = try await withRateLimitedCall(method: "searchMessages") { client in
            try await client.searchMessages(
                chatList: .chatListMain,
                chatTypeFilter: chatTypeFilter,
                filter: nil,
                limit: limit,
                maxDate: 0,
                minDate: 0,
                offset: "",
                query: query
            )
        }

        return result.messages.compactMap { mapMessage($0) }
    }

    func searchChatMessages(chatId: Int64, query: String, limit: Int = 50) async throws -> [TGMessage] {
        guard !query.isEmpty else { return [] }
        let result = try await withRateLimitedCall(method: "searchChatMessages") { client in
            try await client.searchChatMessages(
                chatId: chatId,
                filter: nil,
                fromMessageId: 0,
                limit: limit,
                offset: 0,
                query: query,
                senderId: nil,
                topicId: nil
            )
        }

        return result.messages.compactMap { mapMessage($0) }
    }

    func localSearch(query: String, chatIds: [Int64]? = nil, limit: Int = 50) async -> [TGMessage] {
        let records = await DatabaseManager.shared.localSearch(query: query, chatIds: chatIds, limit: limit)
        return records.map { mapStoredMessage($0) }
    }

    func localScoredSearch(query: String, chatIds: [Int64]? = nil, limit: Int = 50) async -> [LocalMessageSearchHit] {
        let records = await DatabaseManager.shared.localSearchScored(query: query, chatIds: chatIds, limit: limit)
        return records.map { record in
            LocalMessageSearchHit(
                message: mapStoredMessage(record.message),
                score: record.score
            )
        }
    }

    func localVectorSearch(query: String, chatIds: [Int64]? = nil, limit: Int = 50) async -> [LocalMessageSearchHit] {
        guard let queryVector = await EmbeddingService.shared.embed(text: query) else { return [] }

        let searchResults = await VectorStore.shared.search(query: queryVector, topK: limit, chatIds: chatIds)
        guard !searchResults.isEmpty else { return [] }

        let records = await DatabaseManager.shared.loadMessages(
            keys: searchResults.map { result in
                DatabaseManager.MessageLookupKey(
                    messageId: result.messageId,
                    chatId: result.chatId
                )
            }
        )

        let recordByKey = Dictionary(
            uniqueKeysWithValues: records.map { record in
                (
                    DatabaseManager.MessageLookupKey(messageId: record.id, chatId: record.chatId),
                    record
                )
            }
        )

        return searchResults.compactMap { result in
            let key = DatabaseManager.MessageLookupKey(messageId: result.messageId, chatId: result.chatId)
            guard let record = recordByKey[key] else { return nil }
            return LocalMessageSearchHit(
                message: mapStoredMessage(record),
                score: result.score
            )
        }
    }

    // MARK: - User Info (read-only)

    func getUser(id: Int64, priority: RateLimiter.Priority = .userInitiated) async throws -> TGUser? {
        if let cached = userCache[id] { return cached }

        let user = try await withRateLimitedCall(priority: priority, method: "getUser") { client in
            try await client.getUser(userId: id)
        }
        let tgUser = mapUser(user)
        userCache[tgUser.id] = tgUser
        return tgUser
    }

    /// Hydrates private-chat user metadata so sync bot filters can rely on cached bot flags.
    func warmPrivateChatUserMetadata(
        for chats: [TGChat],
        priority: RateLimiter.Priority = .background
    ) async -> Bool {
        let uncachedUserIds = Set(chats.compactMap { chat -> Int64? in
            guard case .privateChat(let userId) = chat.chatType else { return nil }
            guard userCache[userId] == nil else { return nil }
            return userId
        })

        guard !uncachedUserIds.isEmpty else { return false }

        var hydratedAny = false

        for userId in uncachedUserIds {
            guard !Task.isCancelled else { break }
            guard userCache[userId] == nil else { continue }

            do {
                if let _ = try await getUser(id: userId, priority: priority) {
                    hydratedAny = true
                }
            } catch {
                continue
            }

            if userCache[userId] != nil {
                hydratedAny = true
            }
        }

        return hydratedAny
    }

    func ensureBotFilterMetadataReady(
        for chats: [TGChat],
        includeBots: Bool,
        priority: RateLimiter.Priority = .background
    ) async {
        guard !includeBots else { return }

        let hydratedAny = await warmPrivateChatUserMetadata(for: chats, priority: priority)
        guard hydratedAny else { return }
        botMetadataRefreshVersion += 1
    }

    func scheduleBotMetadataWarm(
        for chats: [TGChat],
        includeBots: Bool,
        priority: RateLimiter.Priority = .background
    ) {
        guard !includeBots else {
            botMetadataWarmTask?.cancel()
            return
        }

        botMetadataWarmTask?.cancel()
        botMetadataWarmTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let hydratedAny = await self.warmPrivateChatUserMetadata(for: chats, priority: priority)
            guard hydratedAny, !Task.isCancelled else { return }
            self.botMetadataRefreshVersion += 1
        }
    }

    func cancelBotMetadataWarm() {
        botMetadataWarmTask?.cancel()
    }

    /// Lightweight bot check for private chats used by AI search filters.
    /// Uses only cached Telegram user metadata; unknown users are treated as non-bots
    /// until metadata hydration completes.
    func isLikelyBotChat(_ chat: TGChat) -> Bool {
        guard case .privateChat(let userId) = chat.chatType else { return false }

        if let cachedUser = userCache[userId] {
            return cachedUser.isBot
        }

        return false
    }

    /// Strong bot check for private chats using Telegram's user.type metadata.
    func isBotChat(_ chat: TGChat) async -> Bool {
        guard case .privateChat(let userId) = chat.chatType else { return false }

        if let cachedUser = userCache[userId] {
            return cachedUser.isBot
        }

        if let user = try? await getUser(id: userId) {
            return user.isBot
        }

        return false
    }

    /// Resolves username/phone hints for deep-link generation.
    /// Uses lightweight TDLib lookups and local caches when available.
    func getDeepLinkHints(for chat: TGChat) async -> (username: String?, phoneNumber: String?) {
        switch chat.chatType {
        case .privateChat(let userId):
            if let cached = userCache[userId] {
                return (cached.username, cached.phoneNumber)
            }
            if let user = try? await getUser(id: userId) {
                return (user.username, user.phoneNumber)
            }
            return (nil, nil)

        case .supergroup(let supergroupId, _):
            if let supergroup = try? await withRateLimitedCall(method: "getSupergroup", operation: { client in
                try await client.getSupergroup(supergroupId: supergroupId)
            }) {
                return (supergroup.usernames?.activeUsernames.first, nil)
            }
            return (nil, nil)

        case .basicGroup, .secretChat:
            return (nil, nil)
        }
    }

    private func fetchBasicGroupMemberCount(groupId: Int64) async -> Int? {
        guard let basicGroup = try? await withRateLimitedCall(method: "getBasicGroup", operation: { client in
            try await client.getBasicGroup(basicGroupId: groupId)
        }) else {
            return nil
        }

        return normalizedMemberCount(basicGroup.memberCount)
    }

    private func fetchSupergroupMemberCount(supergroupId: Int64) async -> Int? {
        if let fullInfo = try? await withRateLimitedCall(method: "getSupergroupFullInfo", operation: { client in
            try await client.getSupergroupFullInfo(supergroupId: supergroupId)
        }),
           let memberCount = normalizedMemberCount(fullInfo.memberCount) {
            return memberCount
        }

        if let supergroup = try? await withRateLimitedCall(method: "getSupergroup", operation: { client in
            try await client.getSupergroup(supergroupId: supergroupId)
        }),
           let memberCount = normalizedMemberCount(supergroup.memberCount) {
            return memberCount
        }

        return nil
    }

    private func cacheMemberCount(_ memberCount: Int, for chatId: Int64) {
        guard let cached = chatCache[chatId], cached.memberCount != memberCount else {
            return
        }

        let updated = cached.updating(memberCount: memberCount)
        chatCache[chatId] = updated

        if let index = chats.firstIndex(where: { $0.id == chatId }) {
            chats[index] = updated
        }
    }

    // MARK: - Update Handling

    private func handleUpdate(_ update: Update) {
        switch update {
        case .updateAuthorizationState(let authUpdate):
            handleAuthState(authUpdate.authorizationState)

        case .updateNewChat(let chatUpdate):
            let tgChat = mapChat(chatUpdate.chat)
            chatCache[tgChat.id] = tgChat
            if let index = chats.firstIndex(where: { $0.id == tgChat.id }) {
                chats[index] = tgChat
            } else {
                chats.append(tgChat)
                sortChats()
            }
            evictCacheIfNeeded()

        case .updateChatLastMessage(let msgUpdate):
            // Push new message into the event-driven cache
            if let rawMsg = msgUpdate.lastMessage {
                let tgMsg = mapMessage(rawMsg)
                Task { await MessageCacheService.shared.appendMessage(chatId: msgUpdate.chatId, message: tgMsg) }
            }

            if let index = chats.firstIndex(where: { $0.id == msgUpdate.chatId }) {
                let lastMsg = msgUpdate.lastMessage.map { mapMessage($0) }
                // Preserve existing order/mainList if positions is empty (only message changed)
                let newOrder = msgUpdate.positions.isEmpty
                    ? chats[index].order
                    : extractOrder(from: msgUpdate.positions)
                let inMainList = msgUpdate.positions.isEmpty
                    ? chats[index].isInMainList
                    : msgUpdate.positions.contains(where: {
                        if case .chatListMain = $0.list { return true }
                        return false
                    })
                let updated = TGChat(
                    id: chats[index].id,
                    title: chats[index].title,
                    chatType: chats[index].chatType,
                    unreadCount: chats[index].unreadCount,
                    lastMessage: lastMsg,
                    memberCount: chats[index].memberCount,
                    order: newOrder,
                    isInMainList: inMainList,
                    smallPhotoFileId: chats[index].smallPhotoFileId
                )
                chats[index] = updated
                chatCache[updated.id] = updated
                sortChats()
            }

        case .updateMessageContent(let contentUpdate):
            let (textContent, mediaType) = extractContent(from: contentUpdate.newContent)
            Task {
                await MessageCacheService.shared.updateMessageContent(
                    chatId: contentUpdate.chatId,
                    messageId: contentUpdate.messageId,
                    textContent: textContent,
                    mediaType: mediaType
                )
                // Content edits can change follow-up semantics; force fresh categorization next run.
                await MessageCacheService.shared.invalidatePipelineCategory(chatId: contentUpdate.chatId)
            }

        case .updateDeleteMessages(let deleteUpdate):
            Task {
                await MessageCacheService.shared.deleteMessages(
                    chatId: deleteUpdate.chatId,
                    messageIds: deleteUpdate.messageIds
                )
                // Deletions can alter conversation state; avoid stale cached AI category.
                await MessageCacheService.shared.invalidatePipelineCategory(chatId: deleteUpdate.chatId)
            }

        case .updateChatPosition(let posUpdate):
            if let index = chats.firstIndex(where: { $0.id == posUpdate.chatId }) {
                let chat = chats[index]
                if case .chatListMain = posUpdate.position.list {
                    let newOrder = posUpdate.position.order.rawValue
                    let updated = TGChat(
                        id: chat.id,
                        title: chat.title,
                        chatType: chat.chatType,
                        unreadCount: chat.unreadCount,
                        lastMessage: chat.lastMessage,
                        memberCount: chat.memberCount,
                        order: newOrder,
                        isInMainList: newOrder > 0,
                        smallPhotoFileId: chat.smallPhotoFileId
                    )
                    chats[index] = updated
                    chatCache[updated.id] = updated
                    sortChats()
                }
            }

        case .updateChatRemovedFromList(let removedUpdate):
            if case .chatListMain = removedUpdate.chatList {
                if let index = chats.firstIndex(where: { $0.id == removedUpdate.chatId }) {
                    let chat = chats[index]
                    let updated = TGChat(
                        id: chat.id,
                        title: chat.title,
                        chatType: chat.chatType,
                        unreadCount: chat.unreadCount,
                        lastMessage: chat.lastMessage,
                        memberCount: chat.memberCount,
                        order: 0,
                        isInMainList: false,
                        smallPhotoFileId: chat.smallPhotoFileId
                    )
                    chats[index] = updated
                    chatCache[updated.id] = updated
                }
            }

        case .updateChatReadInbox(let readUpdate):
            if let index = chats.firstIndex(where: { $0.id == readUpdate.chatId }) {
                let chat = chats[index]
                chats[index] = TGChat(
                    id: chat.id,
                    title: chat.title,
                    chatType: chat.chatType,
                    unreadCount: readUpdate.unreadCount,
                    lastMessage: chat.lastMessage,
                    memberCount: chat.memberCount,
                    order: chat.order,
                    isInMainList: chat.isInMainList,
                    smallPhotoFileId: chat.smallPhotoFileId
                )
                chatCache[chat.id] = chats[index]
            }

        case .updateUser(let userUpdate):
            let tgUser = mapUser(userUpdate.user)
            userCache[tgUser.id] = tgUser

        case .updateConnectionState(let connectionUpdate):
            handleConnectionState(connectionUpdate.state)

        default:
            break
        }
    }

    private func handleAuthState(_ state: AuthorizationState) {
        switch state {
        case .authorizationStateWaitTdlibParameters:
            authState = .waitingForParameters

        case .authorizationStateWaitPhoneNumber:
            authState = .waitingForPhoneNumber

        case .authorizationStateWaitOtherDeviceConfirmation(let info):
            authState = .waitingForQrCode(link: info.link)

        case .authorizationStateWaitCode(let info):
            authState = .waitingForCode(codeInfo: CodeInfo(
                phoneNumber: info.codeInfo.phoneNumber,
                timeout: info.codeInfo.timeout
            ))

        case .authorizationStateWaitPassword(let info):
            authState = .waitingForPassword(hint: info.passwordHint)

        case .authorizationStateReady:
            authState = .ready
            Task {
                try? await loadChats()
                startBackgroundChatDiscovery()
                if let me = try? await fetchCurrentUser() {
                    currentUser = me
                }
            }

        case .authorizationStateLoggingOut:
            chatDiscoveryTask?.cancel()
            authState = .loggingOut

        case .authorizationStateClosed:
            chatDiscoveryTask?.cancel()
            authState = .closed

        case .authorizationStateClosing:
            chatDiscoveryTask?.cancel()
            authState = .closing

        default:
            break
        }
    }

    private func handleConnectionState(_ state: ConnectionState) {
        let previous = connectionState
        connectionState = state

        guard Self.shouldTriggerRecoveryRefresh(
            previousConnectionState: previous,
            newConnectionState: state,
            authState: authState
        ) else {
            return
        }

        Task {
            try? await loadChats(
                limit: AppConstants.Fetch.chatListLimit,
                priority: .background,
                updatesLoadingState: false
            )
            startBackgroundChatDiscovery()
            await RecentSyncCoordinator.shared.recoverNow()
        }
    }

    nonisolated private static func shouldTriggerRecoveryRefresh(
        previousConnectionState: ConnectionState?,
        newConnectionState: ConnectionState,
        authState: AuthState
    ) -> Bool {
        guard authState == .ready else { return false }
        guard let previousConnectionState else { return false }
        return previousConnectionState != .connectionStateReady
            && newConnectionState == .connectionStateReady
    }

#if DEBUG
    nonisolated static func shouldTriggerRecoveryRefreshForTesting(
        previousConnectionState: ConnectionState?,
        newConnectionState: ConnectionState,
        authState: AuthState
    ) -> Bool {
        shouldTriggerRecoveryRefresh(
            previousConnectionState: previousConnectionState,
            newConnectionState: newConnectionState,
            authState: authState
        )
    }
#endif

    // MARK: - Mapping from TDLibKit types to domain models

    private func mapChat(_ chat: TDLibKit.Chat) -> TGChat {
        let chatType: TGChat.ChatType
        switch chat.type {
        case .chatTypePrivate(let info):
            chatType = .privateChat(userId: info.userId)
        case .chatTypeBasicGroup(let info):
            chatType = .basicGroup(groupId: info.basicGroupId)
        case .chatTypeSupergroup(let info):
            chatType = .supergroup(supergroupId: info.supergroupId, isChannel: info.isChannel)
        case .chatTypeSecret(let info):
            chatType = .secretChat(secretChatId: info.secretChatId)
        }

        let lastMsg = chat.lastMessage.map { mapMessage($0) }
        let order = extractOrder(from: chat.positions)
        // Default to true: we only load chatListMain, so newly received chats
        // are assumed to be in the main list. Only updateChatPosition(order=0) or
        // updateChatRemovedFromList will set this to false.
        let isInMain = chat.positions.isEmpty
            ? true
            : chat.positions.contains(where: {
                if case .chatListMain = $0.list { return $0.order.rawValue > 0 }
                return false
            })

        return TGChat(
            id: chat.id,
            title: chat.title,
            chatType: chatType,
            unreadCount: chat.unreadCount,
            lastMessage: lastMsg,
            memberCount: nil,
            order: order,
            isInMainList: isInMain,
            smallPhotoFileId: chat.photo?.small.id
        )
    }

    private func mapMessage(_ message: TDLibKit.Message) -> TGMessage {
        let senderId: TGMessage.MessageSenderId
        switch message.senderId {
        case .messageSenderUser(let user):
            senderId = .user(user.userId)
        case .messageSenderChat(let chat):
            senderId = .chat(chat.chatId)
        }

        let (text, mediaType) = extractContent(from: message.content)

        let chatTitle = chatCache[message.chatId]?.title
        var senderName: String? = nil
        if case .user(let userId) = senderId {
            senderName = userCache[userId]?.displayName
        }

        return TGMessage(
            id: message.id,
            chatId: message.chatId,
            senderId: senderId,
            date: Date(timeIntervalSince1970: TimeInterval(message.date)),
            textContent: text,
            mediaType: mediaType,
            isOutgoing: message.isOutgoing,
            chatTitle: chatTitle,
            senderName: senderName
        )
    }

    private func mapStoredMessage(_ record: DatabaseManager.MessageRecord) -> TGMessage {
        let senderId: TGMessage.MessageSenderId
        if let senderUserId = record.senderUserId {
            senderId = .user(senderUserId)
        } else {
            senderId = .chat(record.chatId)
        }

        let senderName = record.senderName ?? {
            guard let senderUserId = record.senderUserId else { return nil }
            return userCache[senderUserId]?.displayName
        }()

        return TGMessage(
            id: record.id,
            chatId: record.chatId,
            senderId: senderId,
            date: record.date,
            textContent: record.textContent,
            mediaType: record.mediaTypeRaw.flatMap { TGMessage.MediaType(rawValue: $0) },
            isOutgoing: record.isOutgoing,
            chatTitle: chatCache[record.chatId]?.title,
            senderName: senderName
        )
    }

    private func mapUser(_ user: TDLibKit.User) -> TGUser {
        let isBot: Bool
        if case .userTypeBot = user.type {
            isBot = true
        } else {
            isBot = false
        }

        return TGUser(
            id: user.id,
            firstName: user.firstName,
            lastName: user.lastName,
            username: user.usernames?.activeUsernames.first,
            phoneNumber: user.phoneNumber.isEmpty ? nil : user.phoneNumber,
            isBot: isBot,
            smallPhotoFileId: user.profilePhoto?.small.id
        )
    }

    private func extractContent(from content: MessageContent) -> (String?, TGMessage.MediaType?) {
        switch content {
        case .messageText(let text):
            return (trimmedPreviewText(text.text.text), nil)
        case .messagePhoto(let photo):
            return (trimmedPreviewText(photo.caption.text), .photo)
        case .messageVideo(let video):
            return (
                trimmedPreviewText(video.caption.text)
                    ?? preferredFileLabel(video.video.fileName)
                    ?? durationLabel(prefix: "Video", duration: video.video.duration),
                .video
            )
        case .messageDocument(let doc):
            return (
                trimmedPreviewText(doc.caption.text)
                    ?? preferredFileLabel(doc.document.fileName)
                    ?? trimmedPreviewText(doc.document.mimeType),
                .document
            )
        case .messageAudio(let audio):
            return (
                trimmedPreviewText(audio.caption.text)
                    ?? audioLabel(audio.audio),
                .audio
            )
        case .messageVoiceNote(let voice):
            return (
                trimmedPreviewText(voice.caption.text)
                    ?? speechRecognitionLabel(voice.voiceNote.speechRecognitionResult)
                    ?? durationLabel(prefix: "Voice note", duration: voice.voiceNote.duration),
                .voice
            )
        case .messageVideoNote(let videoNote):
            return (
                speechRecognitionLabel(videoNote.videoNote.speechRecognitionResult)
                    ?? durationLabel(prefix: "Video note", duration: videoNote.videoNote.duration),
                .video
            )
        case .messageSticker(let sticker):
            return (trimmedPreviewText(sticker.sticker.emoji) ?? "Sticker", .sticker)
        case .messageAnimation(let anim):
            return (
                trimmedPreviewText(anim.caption.text)
                    ?? preferredFileLabel(anim.animation.fileName)
                    ?? "GIF",
                .animation
            )
        case .messageContact(let contact):
            return (contactLabel(contact.contact), .other)
        case .messagePoll(let poll):
            return (trimmedPreviewText(poll.poll.question.text) ?? "Poll", .other)
        case .messageVenue(let venue):
            return (
                trimmedPreviewText(venue.venue.title)
                    ?? trimmedPreviewText(venue.venue.address)
                    ?? "Venue",
                .other
            )
        case .messageLocation(let location):
            return (location.livePeriod > 0 ? "Live location" : "Location", .other)
        case .messageAnimatedEmoji(let emoji):
            return (trimmedPreviewText(emoji.emoji) ?? "Emoji", .other)
        case .messageDice(let dice):
            return (diceLabel(emoji: dice.emoji, value: dice.value), .other)
        default:
            return (nil, .other)
        }
    }

    private func trimmedPreviewText(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func preferredFileLabel(_ fileName: String) -> String? {
        trimmedPreviewText(fileName)
    }

    private func audioLabel(_ audio: Audio) -> String? {
        let title = trimmedPreviewText(audio.title)
        let performer = trimmedPreviewText(audio.performer)

        if let title, let performer {
            return "\(title) - \(performer)"
        }
        if let title { return title }
        if let performer { return performer }
        if let fileName = preferredFileLabel(audio.fileName) { return fileName }
        return durationLabel(prefix: "Audio", duration: audio.duration)
    }

    private func speechRecognitionLabel(_ result: SpeechRecognitionResult?) -> String? {
        guard let result else { return nil }
        switch result {
        case .speechRecognitionResultText(let text):
            return trimmedPreviewText(text.text)
        case .speechRecognitionResultPending(let pending):
            return trimmedPreviewText(pending.partialText)
        case .speechRecognitionResultError:
            return nil
        }
    }

    private func contactLabel(_ contact: Contact) -> String {
        let first = trimmedPreviewText(contact.firstName)
        let last = trimmedPreviewText(contact.lastName)
        let fullName = [first, last].compactMap { $0 }.joined(separator: " ")
        if !fullName.isEmpty {
            return "Contact: \(fullName)"
        }
        if let phone = trimmedPreviewText(contact.phoneNumber) {
            return "Contact: \(phone)"
        }
        return "Contact"
    }

    private func diceLabel(emoji: String, value: Int) -> String {
        let trimmedEmoji = trimmedPreviewText(emoji) ?? "Dice"
        guard value > 0 else { return trimmedEmoji }
        return "\(trimmedEmoji) \(value)"
    }

    private func durationLabel(prefix: String, duration: Int) -> String {
        guard duration > 0 else { return prefix }
        let minutes = duration / 60
        let seconds = duration % 60
        return "\(prefix) (\(minutes):\(String(format: "%02d", seconds)))"
    }

    private func extractOrder(from positions: [ChatPosition]) -> Int64 {
        positions.first(where: {
            if case .chatListMain = $0.list { return true }
            return false
        })?.order.rawValue ?? 0
    }

    private func sortChats() {
        chats.sort { a, b in
            if a.order != b.order { return a.order > b.order }
            return (a.lastMessage?.date ?? .distantPast) > (b.lastMessage?.date ?? .distantPast)
        }
    }

    // MARK: - Filtered Chat Lists

    /// Chats in the main list (excludes archived chats)
    var visibleChats: [TGChat] {
        chats.filter { $0.isInMainList }
    }

    /// Fetch recent messages from multiple chats
    func getRecentMessagesAcrossChats(chatIds: [Int64], perChatLimit: Int = 20) async throws -> [TGMessage] {
        var allMessages: [TGMessage] = []
        var failCount = 0
        for chatId in chatIds {
            do {
                let messages = try await getChatHistory(chatId: chatId, limit: perChatLimit)
                allMessages.append(contentsOf: messages)
            } catch {
                failCount += 1
                print("[TelegramService] Failed to fetch history for chat \(chatId): \(error)")
            }
        }
        // Surface error if ALL chats failed instead of returning silent empty results
        if allMessages.isEmpty && failCount == chatIds.count && !chatIds.isEmpty {
            throw TGError.allChatsFailed
        }
        return allMessages.sorted { $0.date > $1.date }
    }

    // MARK: - Cache Management

    /// Trims user and chat caches when they exceed configured maximum sizes.
    private func evictCacheIfNeeded() {
        if userCache.count > AppConstants.Cache.maxUserCacheSize {
            let excess = userCache.count - AppConstants.Cache.maxUserCacheSize
            let keysToRemove = Array(userCache.keys.prefix(excess))
            for key in keysToRemove { userCache.removeValue(forKey: key) }
        }
        if chatCache.count > AppConstants.Cache.maxChatCacheSize {
            let excess = chatCache.count - AppConstants.Cache.maxChatCacheSize
            let keysToRemove = Array(chatCache.keys.prefix(excess))
            for key in keysToRemove { chatCache.removeValue(forKey: key) }
        }
    }

    private func fetchCurrentUser() async throws -> TGUser {
        let user = try await withRateLimitedCall(method: "getMe") { client in
            try await client.getMe()
        }
        let tgUser = mapUser(user)
        userCache[tgUser.id] = tgUser
        return tgUser
    }

    private func withRateLimitedCall<T>(
        priority: RateLimiter.Priority = .userInitiated,
        method: String,
        operation: @escaping (TDLibKit.TDLibClient) async throws -> T
    ) async throws -> T {
        guard let client else { throw TGError.clientNotInitialized }

        var attempt = 0
        var pendingFloodWaitSeconds: Int?
        while true {
            attempt += 1
            await rateLimiter.acquire(
                priority: priority,
                method: method,
                floodWaitSeconds: pendingFloodWaitSeconds
            )
            pendingFloodWaitSeconds = nil

            do {
                return try await operation(client)
            } catch let error as TDLibKit.Error {
                guard attempt < 3, let floodWaitSeconds = floodWaitSeconds(from: error) else {
                    throw error
                }

                print("[TelegramService] FLOOD_WAIT detected for \(method): \(floodWaitSeconds)s")
                pendingFloodWaitSeconds = floodWaitSeconds
            }
        }
    }

    private func floodWaitSeconds(from error: TDLibKit.Error) -> Int? {
        let message = error.message.uppercased()

        if let range = message.range(of: "FLOOD_WAIT_") {
            let suffix = message[range.upperBound...]
            let digits = suffix.prefix { $0.isNumber }
            if let seconds = Int(digits) {
                return seconds
            }
        }

        if let range = message.range(of: "RETRY AFTER ") {
            let suffix = message[range.upperBound...]
            let digits = suffix.prefix { $0.isNumber }
            if let seconds = Int(digits) {
                return seconds
            }
        }

        return nil
    }
}
