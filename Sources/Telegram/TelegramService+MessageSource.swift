import Foundation

extension TelegramService: MessageSource {
    nonisolated var sourceID: SourceID { .telegram }
    var isReady: Bool { authState == .ready }

    func chatHistory(chatId: Int64, fromMessageId: Int64, limit: Int) async throws -> [TGMessage] {
        try await getChatHistory(chatId: chatId, fromMessageId: fromMessageId, limit: limit)
    }

    func user(id: Int64) async throws -> TGUser? { try await getUser(id: id) }
    func isLikelyBot(chat: TGChat) -> Bool { isLikelyBotChat(chat) }
}
