import Foundation

struct TGChat: Identifiable, Equatable, Sendable {
    let id: Int64
    let title: String
    let chatType: ChatType
    let unreadCount: Int
    let lastMessage: TGMessage?
    let memberCount: Int?
    let order: Int64
    let isInMainList: Bool
    let smallPhotoFileId: Int?
    /// Which account this chat came from — provider + which login.
    /// Defaults to `.telegram` so every existing call site is unchanged;
    /// a Slack adapter passes `SourceID(kind: .slack, account: teamId)`.
    let source: SourceID
    /// Optional remote avatar URL (e.g. a Slack DM counterpart's photo).
    /// Nil for Telegram (which uses `smallPhotoFileId`) and for channels.
    let avatarURL: String?

    init(
        id: Int64,
        title: String,
        chatType: ChatType,
        unreadCount: Int,
        lastMessage: TGMessage?,
        memberCount: Int?,
        order: Int64,
        isInMainList: Bool,
        smallPhotoFileId: Int?,
        source: SourceID = .telegram,
        avatarURL: String? = nil
    ) {
        self.id = id
        self.title = title
        self.chatType = chatType
        self.unreadCount = unreadCount
        self.lastMessage = lastMessage
        self.memberCount = memberCount
        self.order = order
        self.isInMainList = isInMainList
        self.smallPhotoFileId = smallPhotoFileId
        self.source = source
        self.avatarURL = avatarURL
    }

    enum ChatType: Equatable, Sendable {
        case privateChat(userId: Int64)
        case basicGroup(groupId: Int64)
        case supergroup(supergroupId: Int64, isChannel: Bool)
        case secretChat(secretChatId: Int)

        var displayName: String {
            switch self {
            case .privateChat: return "DM"
            case .basicGroup: return "Group"
            case .supergroup(_, let isChannel): return isChannel ? "Channel" : "Supergroup"
            case .secretChat: return "Secret"
            }
        }

        /// Basic groups + supergroups (not channels)
        var isGroup: Bool {
            switch self {
            case .basicGroup: return true
            case .supergroup(_, let isChannel): return !isChannel
            default: return false
            }
        }

        var isChannel: Bool {
            if case .supergroup(_, let ch) = self { return ch }
            return false
        }

        var isPrivate: Bool {
            if case .privateChat = self { return true }
            return false
        }

        /// True for 1:1 conversations (DM + secret chat). Drives the
        /// circle vs squircle avatar choice — Telegram's convention is
        /// circles for people, rounded squares for groups/channels.
        var isOneOnOne: Bool {
            switch self {
            case .privateChat, .secretChat: return true
            case .basicGroup, .supergroup: return false
            }
        }
    }

    var lastActivityDate: Date? {
        lastMessage?.date
    }

    var initials: String {
        let words = title.split(separator: " ")
        if words.count >= 2 {
            return "\(words[0].prefix(1))\(words[1].prefix(1))".uppercased()
        } else if let first = words.first {
            return String(first.prefix(2)).uppercased()
        }
        return "?"
    }

    /// Consistent color index based on chat ID
    var colorIndex: Int {
        abs(Int(id % 8))
    }

    func updating(memberCount: Int?) -> TGChat {
        TGChat(
            id: id,
            title: title,
            chatType: chatType,
            unreadCount: unreadCount,
            lastMessage: lastMessage,
            memberCount: memberCount,
            order: order,
            isInMainList: isInMainList,
            smallPhotoFileId: smallPhotoFileId,
            source: source,
            avatarURL: avatarURL
        )
    }

    func updating(lastMessage: TGMessage?) -> TGChat {
        TGChat(
            id: id,
            title: title,
            chatType: chatType,
            unreadCount: unreadCount,
            lastMessage: lastMessage,
            memberCount: memberCount,
            order: order,
            isInMainList: isInMainList,
            smallPhotoFileId: smallPhotoFileId,
            source: source,
            avatarURL: avatarURL
        )
    }
}
