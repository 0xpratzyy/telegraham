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

/// Groups FollowUpItems by category for the sectioned Pipeline view.
struct PipelineSection: Identifiable {
    let category: FollowUpItem.Category
    let items: [FollowUpItem]

    var id: FollowUpItem.Category { category }

    var title: String {
        switch category {
        case .onMe: return "ON ME"
        case .onThem: return "ON THEM"
        case .quiet: return "QUIET"
        }
    }

    var icon: String {
        switch category {
        case .onMe: return "envelope.badge"
        case .onThem: return "clock.arrow.circlepath"
        case .quiet: return "moon.zzz"
        }
    }
}
