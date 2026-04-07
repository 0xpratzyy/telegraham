import Foundation
import SwiftUI

struct PatternSearchResult: Identifiable, Sendable, Equatable {
    enum MatchKind: String, Codable, Sendable {
        case exactPhrase = "exact_phrase"
        case walletAddress = "wallet_address"
        case evmAddress = "evm_address"
        case longAddress = "long_address"
        case url = "url"
        case domain = "domain"
        case handle = "handle"
        case literalToken = "literal_token"

        var label: String {
            switch self {
            case .exactPhrase: return "PHRASE"
            case .walletAddress: return "WALLET"
            case .evmAddress: return "0x"
            case .longAddress: return "ADDR"
            case .url: return "URL"
            case .domain: return "DOMAIN"
            case .handle: return "@HANDLE"
            case .literalToken: return "MATCH"
            }
        }

        var color: Color {
            switch self {
            case .exactPhrase: return .blue
            case .walletAddress, .evmAddress, .longAddress: return .green
            case .url, .domain: return .orange
            case .handle: return .pink
            case .literalToken: return .purple
            }
        }
    }

    let message: TGMessage
    let chat: TGChat?
    let chatTitle: String
    let snippet: String
    let score: Double
    let matchKind: MatchKind
    let matchedValue: String?
    let outgoingBiasApplied: Bool

    var id: String { "\(message.chatId):\(message.id)" }
}

struct ReplyQueueResult: Identifiable, Sendable, Equatable {
    enum Classification: String, Codable, Sendable {
        case onMe = "on_me"
        case onThem = "on_them"
        case quiet = "quiet"
        case needMore = "need_more"
    }

    enum Urgency: String, Codable, Sendable {
        case high
        case medium
        case low

        var warmth: AgenticSearchResult.Warmth {
            switch self {
            case .high: return .hot
            case .medium: return .warm
            case .low: return .cold
            }
        }
    }

    let chatId: Int64
    let chatTitle: String
    let suggestedAction: String
    let reason: String
    let confidence: Double
    let urgency: Urgency
    let classification: Classification
    let supportingMessageIds: [Int64]
    let latestMessageDate: Date
    let score: Int
    let source: String

    var id: Int64 { chatId }

    var replyability: AgenticSearchResult.Replyability {
        switch classification {
        case .onMe: return .replyNow
        case .onThem: return .waitingOnThem
        case .quiet, .needMore: return .unclear
        }
    }
}

struct SummarySearchOutput: Sendable, Equatable {
    let summaryText: String
    let title: String
    let supportingChatId: Int64?
    let supportingMessageIds: [Int64]
}
