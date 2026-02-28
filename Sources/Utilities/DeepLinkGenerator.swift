import AppKit

enum DeepLinkGenerator {
    /// Opens a specific chat in the Telegram app
    static func chatURL(chatId: Int64) -> URL? {
        // For private chats, use user ID; for groups, use internal link
        URL(string: "tg://openmessage?chat_id=\(chatId)")
    }

    /// Opens a specific message in the Telegram app
    static func messageURL(chatId: Int64, messageId: Int64) -> URL? {
        URL(string: "tg://openmessage?chat_id=\(chatId)&message_id=\(messageId)")
    }

    /// Opens a URL in the default application (Telegram)
    static func openInTelegram(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Opens a specific message in Telegram
    static func openMessage(chatId: Int64, messageId: Int64) {
        guard let url = messageURL(chatId: chatId, messageId: messageId) else { return }
        openInTelegram(url)
    }
}
