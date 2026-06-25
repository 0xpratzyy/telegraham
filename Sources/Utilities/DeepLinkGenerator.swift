import AppKit
import Combine

/// Shared "a chat is being opened right now" flag so the tapped "Open in chat"
/// control can show a spinner while we resolve the Telegram deep link — a TDLib
/// username/phone lookup (`getDeepLinkHints`) that isn't instant on a cache miss.
/// Set + cleared by the openChat paths in DashboardView / LauncherView; observed
/// by the buttons. Only one open runs at a time, so a single id is enough.
@MainActor
final class ChatOpenState: ObservableObject {
    static let shared = ChatOpenState()
    @Published var openingChatId: Int64?
    private init() {}
}

/// Where "Open in chat" sends the user. Configurable in Preferences and
/// asked once on the onboarding Done screen; until the user chooses, the
/// default is detected from whether a tg:// handler (Telegram Desktop /
/// macOS Telegram) is installed.
enum ChatOpenTarget: String, CaseIterable, Identifiable {
    case desktop
    case web

    var id: String { rawValue }

    var label: String {
        switch self {
        case .desktop: return "Telegram Desktop"
        case .web: return "Telegram Web"
        }
    }

    /// The user's choice, or the detected default when they never chose.
    static var current: ChatOpenTarget {
        if let raw = UserDefaults.standard.string(forKey: AppConstants.Preferences.chatOpenTargetKey),
           let target = ChatOpenTarget(rawValue: raw) {
            return target
        }
        return detectedDefault()
    }

    /// Desktop when something handles tg:// URLs, web otherwise.
    static func detectedDefault() -> ChatOpenTarget {
        guard let probe = URL(string: "tg://resolve") else { return .web }
        return NSWorkspace.shared.urlForApplication(toOpen: probe) != nil ? .desktop : .web
    }
}

enum DeepLinkGenerator {
    /// TDLib message ids are MTProto server ids shifted left 20 bits.
    /// Telegram's link formats (t.me/c/…, privatepost, openmessage)
    /// expect the SERVER id — passing the raw TDLib id navigates to a
    /// nonsense message. Locally-generated ids (drafts, scheduled) are
    /// not exact multiples of 2^20; return nil for those so callers
    /// skip message anchoring instead of deep-linking to garbage.
    static func serverMessageId(_ tdlibMessageId: Int64) -> Int64? {
        let serverId = tdlibMessageId >> 20
        guard serverId > 0, serverId << 20 == tdlibMessageId else { return nil }
        return serverId
    }

    /// Build candidate links (most specific first; legacy fallbacks
    /// last). Candidates are tried in order until the OS accepts one —
    /// note NSWorkspace only confirms a handler accepted the URL, not
    /// that Telegram navigated successfully, so ORDER matters.
    static func candidateChatURLs(
        chat: TGChat,
        username: String? = nil,
        phoneNumber: String? = nil,
        target: ChatOpenTarget = .current
    ) -> [URL] {
        var candidates: [String] = []

        switch target {
        case .web:
            // Web K accepts #@username, #<user_id> for DMs, and the
            // raw (negative) TDLib chat id for groups and supergroups.
            // Message-level anchors aren't reliably supported — open
            // the chat itself.
            if let username, !username.isEmpty {
                candidates.append("https://web.telegram.org/k/#@\(username)")
            }
            switch chat.chatType {
            case .privateChat(let userId):
                candidates.append("https://web.telegram.org/k/#\(userId)")
            case .basicGroup, .supergroup:
                candidates.append("https://web.telegram.org/k/#\(chat.id)")
            case .secretChat:
                return []
            }

        case .desktop:
            let lastServerMessageId = chat.lastMessage.flatMap { serverMessageId($0.id) }

            switch chat.chatType {
            case .privateChat(let userId):
                if let username, !username.isEmpty {
                    candidates.append("tg://resolve?domain=\(username)")
                }
                if let phone = sanitizePhone(phoneNumber), !phone.isEmpty {
                    candidates.append("tg://resolve?phone=\(phone)")
                }
                if candidates.isEmpty {
                    // No @username and no known phone → the only remaining tg://
                    // options are openmessage?user_id / ?chat_id, which Telegram
                    // Desktop ACCEPTS (so NSWorkspace.open reports success) but
                    // silently refuses to navigate — the same dead behavior as
                    // basic groups, verified live on com.tdesktop.Telegram. Emitting
                    // them would "succeed" and block the web fallback, leaving the
                    // user on whatever Telegram already showed ("opens the app but
                    // not the conversation"). Web K navigates by user id, so a
                    // hint-less DM goes straight there.
                    candidates.append("https://web.telegram.org/k/#\(userId)")
                } else {
                    // resolve?domain / resolve?phone above navigate in-app; keep
                    // openmessage only as a rarely-reached last-ditch (it's never
                    // hit when a resolve link is accepted first).
                    candidates.append("tg://openmessage?user_id=\(userId)")
                    candidates.append("tg://openmessage?chat_id=\(chat.id)")
                }

            case .basicGroup:
                // Basic (legacy, non-super) groups have NO working tg://
                // deep link on macOS: tdesktop accepts
                // tg://openmessage?chat_id=… (so NSWorkspace reports
                // success and fallbacks never fire) but silently refuses
                // to navigate — verified live on com.tdesktop.Telegram
                // 2026-06-11. Telegram Web handles the raw negative chat
                // id reliably, so basic groups go to the browser even
                // when the user prefers the desktop app.
                candidates.append("https://web.telegram.org/k/#\(chat.id)")

            case .supergroup(let supergroupId, _):
                if let username, !username.isEmpty {
                    candidates.append("tg://resolve?domain=\(username)")
                }
                // privatepost / t.me/c need a real message to land on —
                // use the latest message's SERVER id. (This used to
                // hardcode post=1, which is virtually always a deleted
                // message → Telegram showed "message not found".)
                if let lastServerMessageId {
                    candidates.append("tg://privatepost?channel=\(supergroupId)&post=\(lastServerMessageId)")
                    candidates.append("https://t.me/c/\(supergroupId)/\(lastServerMessageId)")
                }
                candidates.append("tg://openmessage?chat_id=\(chat.id)")

            case .secretChat:
                return []
            }
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
        phoneNumber: String? = nil,
        target: ChatOpenTarget = .current
    ) -> Bool {
        let urls = candidateChatURLs(
            chat: chat,
            username: username,
            phoneNumber: phoneNumber,
            target: target
        )
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
