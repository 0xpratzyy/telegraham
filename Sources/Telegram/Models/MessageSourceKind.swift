import Foundation

/// Messaging and mailbox providers supported by Pidgy's unified inbox.
enum MessageSourceKind: String, Equatable, Sendable, Codable, CaseIterable, Identifiable {
    case telegram
    case gmail
    case slack
    case whatsapp

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .telegram: return "Telegram"
        case .gmail: return "Gmail"
        case .slack: return "Slack"
        case .whatsapp: return "WhatsApp"
        }
    }

    var systemImage: String {
        switch self {
        case .telegram: return "paperplane.fill"
        case .gmail: return "envelope.fill"
        case .slack: return "number"
        case .whatsapp: return "bubble.left.and.bubble.right.fill"
        }
    }
}
