import Foundation
import SwiftUI

/// A chat that needs follow-up attention, categorized by conversation state.
struct FollowUpItem: Identifiable {
    let id = UUID()
    let chat: TGChat
    let category: Category
    let lastMessage: TGMessage
    let timeSinceLastActivity: TimeInterval
    var suggestedAction: String?  // nil initially, filled by AI in background

    enum Category: String, CaseIterable {
        case reply = "REPLY"
        case followUp = "FOLLOW UP"
        case stale = "STALE"

        var color: Color {
            switch self {
            case .reply: return .orange
            case .followUp: return .blue
            case .stale: return .gray
            }
        }

        var icon: String {
            switch self {
            case .reply: return "arrowshape.turn.up.left.fill"
            case .followUp: return "arrow.right.circle.fill"
            case .stale: return "clock.fill"
            }
        }
    }
}

/// Groups FollowUpItems by category for the sectioned Pipeline view.
struct PipelineSection: Identifiable {
    let category: FollowUpItem.Category
    let items: [FollowUpItem]

    var id: FollowUpItem.Category { category }

    var title: String {
        switch category {
        case .reply: return "NEEDS REPLY"
        case .followUp: return "WAITING ON THEM"
        case .stale: return "GONE QUIET"
        }
    }

    var icon: String {
        switch category {
        case .reply: return "envelope.badge"
        case .followUp: return "clock.arrow.circlepath"
        case .stale: return "moon.zzz"
        }
    }
}
