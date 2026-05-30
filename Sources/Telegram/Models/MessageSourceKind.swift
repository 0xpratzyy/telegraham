import Foundation

/// Which messaging backend a chat or message originated from.
///
/// Pidgy started Telegram-only, so this defaults to `.telegram`
/// everywhere — every existing call site is unaffected. As a second
/// source (Slack) comes online, its adapter stamps `.slack` on the
/// `TG*` structs it produces, so the rest of the app can route sends,
/// badge rows, and filter by source without caring which backend a
/// given chat came from.
///
/// Kept deliberately tiny and `Sendable` so it can ride along on the
/// domain models with no ceremony.
enum MessageSourceKind: String, Equatable, Sendable, Codable, CaseIterable {
    case telegram
    case slack

    /// Short, user-facing label for badges / filters.
    var displayName: String {
        switch self {
        case .telegram: return "Telegram"
        case .slack: return "Slack"
        }
    }

    /// Asset name for the platform's brand glyph, badged on avatars so a
    /// glance shows which platform a chat came from.
    var glyphAssetName: String {
        switch self {
        case .telegram: return "TelegramGlyph"
        case .slack: return "SlackGlyph"
        }
    }
}
