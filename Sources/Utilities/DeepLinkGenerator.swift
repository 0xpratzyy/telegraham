import AppKit

enum DeepLinkGenerator {
    /// Opens a specific chat in Telegram using proper peer IDs based on chat type.
    static func chatURL(chat: TGChat) -> URL? {
        switch chat.chatType {
        case .privateChat(let userId):
            return URL(string: "tg://user?id=\(userId)")
        case .basicGroup(let groupId):
            return URL(string: "tg://openmessage?chat_id=\(groupId)")
        case .supergroup(let supergroupId, _):
            // t.me/c/ format is more reliable for supergroups on macOS Telegram
            return URL(string: "https://t.me/c/\(supergroupId)/999999999")
        case .secretChat:
            return nil
        }
    }

    /// Opens a URL in Telegram, explicitly targeting the Telegram app if found.
    static func openInTelegram(_ url: URL) {
        // Try known Telegram bundle IDs (App Store + direct download)
        let bundleIds = ["ru.keepcoder.Telegram", "com.tdesktop.Telegram"]
        for bundleId in bundleIds {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                let config = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
                return
            }
        }
        // Fallback to default handler
        NSWorkspace.shared.open(url)
    }
}
