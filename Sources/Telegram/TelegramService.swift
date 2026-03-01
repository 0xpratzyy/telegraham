import Foundation
import TDLibKit

/// Central service for all Telegram operations.
/// Read-only by design — no write/send/modify methods exist.
@MainActor
class TelegramService: ObservableObject {
    @Published var authState: AuthState = .uninitialized
    @Published var chats: [TGChat] = []
    @Published var currentUser: TGUser?
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let tdClient = TDLibClientWrapper()
    private let rateLimiter = RateLimiter()
    private var updateTask: Task<Void, Never>?
    private var userCache: [Int64: TGUser] = [:]
    private var chatCache: [Int64: TGChat] = [:]

    /// The underlying TDLibKit client for direct API calls
    private var client: TDLibKit.TDLibClient? {
        tdClient.client
    }

    // MARK: - Lifecycle

    func start(apiId: Int, apiHash: String) {
        tdClient.start(apiId: apiId, apiHash: apiHash)
        startListeningForUpdates()

        // Set TDLib parameters
        Task {
            try? await setTdlibParameters(apiId: apiId, apiHash: apiHash)
        }
    }

    func stop() {
        updateTask?.cancel()
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

    func logOut() async throws {
        guard let client else { throw TGError.clientNotInitialized }
        _ = try await client.logOut()
    }

    // MARK: - Chat Operations (read-only)

    func loadChats(limit: Int = 100) async throws {
        guard let client else { throw TGError.clientNotInitialized }
        isLoading = true
        defer { isLoading = false }

        await rateLimiter.acquire()
        _ = try await client.loadChats(chatList: .chatListMain, limit: limit)
        // Chats arrive via updateNewChat updates
    }

    func getChat(id: Int64) async throws -> TGChat? {
        if let cached = chatCache[id] { return cached }
        guard let client else { throw TGError.clientNotInitialized }

        let chat = try await client.getChat(chatId: id)
        let tgChat = mapChat(chat)
        chatCache[tgChat.id] = tgChat
        return tgChat
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

    func getChatHistory(chatId: Int64, fromMessageId: Int64 = 0, limit: Int = 50, onlyLocal: Bool = false) async throws -> [TGMessage] {
        guard let client else { throw TGError.clientNotInitialized }
        await rateLimiter.acquire()

        let result = try await client.getChatHistory(
            chatId: chatId,
            fromMessageId: fromMessageId,
            limit: limit,
            offset: 0,
            onlyLocal: onlyLocal
        )

        return (result.messages ?? []).compactMap { mapMessage($0) }
    }

    // MARK: - Search (read-only)

    func searchMessages(query: String, limit: Int = 50) async throws -> [TGMessage] {
        guard !query.isEmpty else { return [] }
        guard let client else { throw TGError.clientNotInitialized }

        await rateLimiter.acquire()

        let result = try await client.searchMessages(
            chatList: .chatListMain,
            chatTypeFilter: nil,
            filter: nil,
            limit: limit,
            maxDate: 0,
            minDate: 0,
            offset: "",
            query: query
        )

        return (result.messages ?? []).compactMap { mapMessage($0) }
    }

    func searchChatMessages(chatId: Int64, query: String, limit: Int = 50) async throws -> [TGMessage] {
        guard !query.isEmpty else { return [] }
        guard let client else { throw TGError.clientNotInitialized }

        await rateLimiter.acquire()

        let result = try await client.searchChatMessages(
            chatId: chatId,
            filter: nil,
            fromMessageId: 0,
            limit: limit,
            offset: 0,
            query: query,
            senderId: nil,
            topicId: nil
        )

        return (result.messages ?? []).compactMap { mapMessage($0) }
    }

    // MARK: - User Info (read-only)

    func getUser(id: Int64) async throws -> TGUser? {
        if let cached = userCache[id] { return cached }
        guard let client else { throw TGError.clientNotInitialized }

        let user = try await client.getUser(userId: id)
        let tgUser = mapUser(user)
        userCache[tgUser.id] = tgUser
        return tgUser
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
                if let client {
                    if let me = try? await client.getMe() {
                        currentUser = mapUser(me)
                    }
                }
            }

        case .authorizationStateLoggingOut:
            authState = .loggingOut

        case .authorizationStateClosed:
            authState = .closed

        case .authorizationStateClosing:
            authState = .closing

        default:
            break
        }
    }

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
            chatTitle: chatTitle,
            senderName: senderName
        )
    }

    private func mapUser(_ user: TDLibKit.User) -> TGUser {
        TGUser(
            id: user.id,
            firstName: user.firstName,
            lastName: user.lastName,
            username: user.usernames?.activeUsernames.first,
            phoneNumber: user.phoneNumber.isEmpty ? nil : user.phoneNumber
        )
    }

    private func extractContent(from content: MessageContent) -> (String?, TGMessage.MediaType?) {
        switch content {
        case .messageText(let text):
            return (text.text.text, nil)
        case .messagePhoto(let photo):
            return (photo.caption.text.isEmpty ? nil : photo.caption.text, .photo)
        case .messageVideo(let video):
            return (video.caption.text.isEmpty ? nil : video.caption.text, .video)
        case .messageDocument(let doc):
            return (doc.caption.text.isEmpty ? nil : doc.caption.text, .document)
        case .messageAudio(let audio):
            return (audio.caption.text.isEmpty ? nil : audio.caption.text, .audio)
        case .messageVoiceNote(let voice):
            return (voice.caption.text.isEmpty ? nil : voice.caption.text, .voice)
        case .messageSticker:
            return (nil, .sticker)
        case .messageAnimation(let anim):
            return (anim.caption.text.isEmpty ? nil : anim.caption.text, .animation)
        default:
            return (nil, .other)
        }
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
}
