import Foundation

struct TGChat: Identifiable, Equatable {
    let id: Int64
    let title: String
    let chatType: ChatType
    let unreadCount: Int
    let lastMessage: TGMessage?
    let memberCount: Int?
    let order: Int64

    enum ChatType: Equatable {
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

        var isGroup: Bool {
            switch self {
            case .basicGroup, .supergroup: return true
            default: return false
            }
        }

        var isPrivate: Bool {
            if case .privateChat = self { return true }
            return false
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
}
