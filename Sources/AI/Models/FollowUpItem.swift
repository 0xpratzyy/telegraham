import Foundation
import SwiftUI

/// A chat that needs follow-up attention, categorized by AI analysis of conversation state.
struct FollowUpItem: Identifiable, Sendable {
    // Stable identity (one item per chat) so re-projections diff rows in place
    // instead of replacing every row — a fresh UUID per projection made the list
    // re-render mid-click, so the first click landed on a stale row ("click twice").
    var id: Int64 { chat.id }
    let chat: TGChat
    let category: Category
    let lastMessage: TGMessage
    let timeSinceLastActivity: TimeInterval
    var suggestedAction: String?
    /// The open-loop fact that put this chat ON ME: its trigger message id and
    /// evidence text, so the detail's Evidence anchors on the real loop source
    /// rather than the chat's latest (often unrelated) message.
    var loopSourceMessageId: Int64? = nil
    var loopEvidence: String? = nil
    /// When the ask actually happened (the loop's source date) — used to rank +
    /// timestamp ON ME items by the AGE OF THE ASK, not the chat's latest message.
    var loopDate: Date? = nil
    /// The loop's counterparty (fact subject) — labels the evidence fallback row
    /// with the ASKER, not whoever happened to send the chat's last message.
    var loopPersonName: String? = nil

    enum Category: String, CaseIterable, Sendable {
        case onMe = "ON ME"
        case onThem = "ON THEM"
        case quiet = "QUIET"

        var color: Color {
            switch self {
            case .onMe: return Color.Pidgy.warning
            case .onThem: return Color.Pidgy.accent
            case .quiet: return Color.Pidgy.fg2
            }
        }

        var icon: String {
            switch self {
            case .onMe: return "arrowshape.turn.up.left.fill"
            case .onThem: return "arrow.right.circle.fill"
            case .quiet: return "clock.fill"
            }
        }
    }
}
