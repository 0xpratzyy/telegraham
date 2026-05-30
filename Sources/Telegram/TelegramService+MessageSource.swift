import Foundation

/// Conforms `TelegramService` to the source-neutral `MessageSource`
/// protocol. Pure adapter layer — no behavior change for direct callers
/// of `getChatHistory` / `getUser`, which keep their full Telegram-
/// specific signatures (priority, onlyLocal). Phase 1c migrates
/// consumers from the concrete service to the protocol; this extension
/// is what makes that migration mechanical rather than invasive.
extension TelegramService: MessageSource {
    nonisolated var sourceID: SourceID { .telegram }

    var isReady: Bool { authState == .ready }

    /// Source-neutral overload that delegates to the existing
    /// `getChatHistory(chatId:fromMessageId:limit:onlyLocal:priority:)`
    /// with the defaults a generic consumer would want.
    func chatHistory(chatId: Int64, fromMessageId: Int64, limit: Int) async throws -> [TGMessage] {
        try await getChatHistory(
            chatId: chatId,
            fromMessageId: fromMessageId,
            limit: limit
        )
    }

    /// Source-neutral overload that delegates to the existing
    /// `getUser(id:priority:)` with the default priority.
    func user(id: Int64) async throws -> TGUser? {
        try await getUser(id: id)
    }

    /// Telegram's bot check is the existing `isLikelyBotChat` —
    /// a private chat whose counterpart user is flagged `isBot`.
    func isLikelyBot(chat: TGChat) -> Bool {
        isLikelyBotChat(chat)
    }
}
