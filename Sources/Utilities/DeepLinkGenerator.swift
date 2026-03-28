import AppKit

enum DeepLinkGenerator {
    /// Build multiple candidate deep links (documented first, legacy fallback last).
    /// We try candidates in order until one is accepted by the OS handler.
    static func candidateChatURLs(
        chat: TGChat,
        username: String? = nil,
        phoneNumber: String? = nil
    ) -> [URL] {
        var candidates: [String] = []

        switch chat.chatType {
        case .privateChat(let userId):
            if let username, !username.isEmpty {
                candidates.append("tg://resolve?domain=\(username)")
            }
            if let phone = sanitizePhone(phoneNumber), !phone.isEmpty {
                candidates.append("tg://resolve?phone=\(phone)")
            }
            // Legacy fallbacks for clients that still support them.
            candidates.append("tg://openmessage?chat_id=\(chat.id)")
            candidates.append("tg://user?id=\(userId)")

        case .basicGroup(let groupId):
            // Basic groups don't have public usernames, so keep legacy openmessage fallback.
            candidates.append("tg://openmessage?chat_id=\(chat.id)")
            candidates.append("tg://openmessage?chat_id=\(groupId)")

        case .supergroup(let supergroupId, _):
            if let username, !username.isEmpty {
                candidates.append("tg://resolve?domain=\(username)")
            }
            // Official private message-link format for private supergroups/channels.
            candidates.append("tg://privatepost?channel=\(supergroupId)&post=1")
            candidates.append("https://t.me/c/\(supergroupId)/1")
            // Legacy fallback.
            candidates.append("tg://openmessage?chat_id=\(chat.id)")

        case .secretChat:
            return []
        }

        var seen = Set<String>()
        return candidates
            .filter { seen.insert($0).inserted }
            .compactMap(URL.init(string:))
    }

    /// Attempts to open a specific chat, trying multiple link strategies.
    @discardableResult
    static func openChat(
        _ chat: TGChat,
        username: String? = nil,
        phoneNumber: String? = nil
    ) -> Bool {
        let urls = candidateChatURLs(chat: chat, username: username, phoneNumber: phoneNumber)
        for url in urls where NSWorkspace.shared.open(url) {
            return true
        }
        return false
    }

    /// Opens a URL with the default handler (Telegram for tg:// links).
    @discardableResult
    static func openInTelegram(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    private static func sanitizePhone(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let digits = raw.filter { $0.isNumber }
        return digits.isEmpty ? nil : digits
    }
}
