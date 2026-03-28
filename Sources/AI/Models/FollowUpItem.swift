import Foundation
import SwiftUI

/// A chat that needs follow-up attention, categorized by AI analysis of conversation state.
struct FollowUpItem: Identifiable {
    let id = UUID()
    let chat: TGChat
    let category: Category
    let lastMessage: TGMessage
    let timeSinceLastActivity: TimeInterval
    var suggestedAction: String?

    enum Category: String, CaseIterable {
        case onMe = "ON ME"
        case onThem = "ON THEM"
        case quiet = "QUIET"

        var color: Color {
            switch self {
            case .onMe: return .orange
            case .onThem: return .blue
            case .quiet: return .gray
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
