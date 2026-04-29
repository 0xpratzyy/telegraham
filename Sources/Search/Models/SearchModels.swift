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
        case worthChecking = "worth_checking"
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
        case .worthChecking: return .worthChecking
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

enum AISearchResult: Identifiable {
    case semanticResult(SemanticSearchResult)
    case agenticResult(AgenticSearchResult)
    case patternResult(PatternSearchResult)
    case replyQueueResult(ReplyQueueResult)

    var id: String {
        switch self {
        case .semanticResult(let result): return "sem-\(result.id)"
        case .agenticResult(let result): return "ag-\(result.id)"
        case .patternResult(let result): return "pattern-\(result.id)"
        case .replyQueueResult(let result): return "reply-\(result.id)"
        }
    }
}

struct SearchChatEligibilityFilter {
    struct Exclusion: Equatable {
        let reason: String
        let chatTitle: String
    }

    struct Result {
        let included: [TGChat]
        let exclusions: [Exclusion]
    }

    static func collectCandidateChats(
        from chats: [TGChat],
        scope: QueryScope,
        replyQueueQuery: Bool,
        now: Date = Date()
    ) -> Result {
        var included: [TGChat] = []
        var exclusions: [Exclusion] = []

        for chat in chats {
            guard let lastMessage = chat.lastMessage else {
                exclusions.append(Exclusion(reason: "no last message", chatTitle: chat.title))
                continue
            }
            guard !chat.chatType.isChannel else {
                exclusions.append(Exclusion(reason: "channel skipped", chatTitle: chat.title))
                continue
            }
            guard isChatInScope(chat, scope: scope) else {
                exclusions.append(Exclusion(reason: "outside active scope", chatTitle: chat.title))
                continue
            }

            let ageLimit = maximumAge(for: chat, replyQueueQuery: replyQueueQuery)
            let age = now.timeIntervalSince(lastMessage.date)
            guard age <= ageLimit else {
                let dayLabel = Int(ageLimit / 86_400)
                exclusions.append(Exclusion(reason: "older than \(dayLabel) days", chatTitle: chat.title))
                continue
            }

            if chat.chatType.isGroup {
                if let count = chat.memberCount, count > AppConstants.FollowUp.maxGroupMembers {
                    exclusions.append(Exclusion(reason: "group too large", chatTitle: chat.title))
                    continue
                }
                if chat.unreadCount > AppConstants.FollowUp.maxGroupUnread {
                    exclusions.append(Exclusion(reason: "group unread too high", chatTitle: chat.title))
                    continue
                }
            }

            included.append(chat)
        }

        return Result(included: included, exclusions: exclusions)
    }

    static func applyingLikelyBotFilter(
        to result: Result,
        includeBots: Bool,
        isLikelyBot: (TGChat) -> Bool
    ) -> Result {
        guard !includeBots else { return result }

        var filtered: [TGChat] = []
        var exclusions = result.exclusions
        filtered.reserveCapacity(result.included.count)

        for chat in result.included {
            if isLikelyBot(chat) {
                exclusions.append(Exclusion(reason: "bot filtered", chatTitle: chat.title))
                continue
            }
            filtered.append(chat)
        }

        return Result(included: filtered, exclusions: exclusions)
    }

    static func applyingBotFilter(
        to result: Result,
        includeBots: Bool,
        isBot: (TGChat) async -> Bool
    ) async -> Result {
        guard !includeBots else { return result }

        var filtered: [TGChat] = []
        var exclusions = result.exclusions
        filtered.reserveCapacity(result.included.count)

        for chat in result.included {
            if await isBot(chat) {
                exclusions.append(Exclusion(reason: "bot filtered", chatTitle: chat.title))
                continue
            }
            filtered.append(chat)
        }

        return Result(included: filtered, exclusions: exclusions)
    }

    private static func isChatInScope(_ chat: TGChat, scope: QueryScope) -> Bool {
        switch scope {
        case .all:
            return chat.chatType.isPrivate || chat.chatType.isGroup
        case .dms:
            return chat.chatType.isPrivate
        case .groups:
            return chat.chatType.isGroup
        }
    }

    private static func maximumAge(for chat: TGChat, replyQueueQuery: Bool) -> TimeInterval {
        if replyQueueQuery && chat.chatType.isPrivate {
            return AppConstants.AI.AgenticSearch.replyQueuePrivateMaxAgeSeconds
        }
        return AppConstants.FollowUp.maxPipelineAgeSeconds
    }
}

struct LauncherVisibleChatsFilter {
    static func filterChats(
        from chats: [TGChat],
        scope: QueryScope,
        pipelineMatchingIds: Set<Int64>?,
        searchText: String,
        searchResultChatIds: Set<Int64>,
        includeBots: Bool,
        isLikelyBot: (TGChat) -> Bool
    ) -> [TGChat] {
        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        return chats.filter { chat in
            guard chatMatchesScope(chat, scope: scope) else { return false }
            guard includeBots || !isLikelyBot(chat) else { return false }

            if let pipelineMatchingIds,
               !pipelineMatchingIds.contains(chat.id) {
                return false
            }

            guard !trimmedSearchText.isEmpty else { return true }

            return chat.title.localizedCaseInsensitiveContains(trimmedSearchText)
                || searchResultChatIds.contains(chat.id)
        }
    }

    private static func chatMatchesScope(_ chat: TGChat, scope: QueryScope) -> Bool {
        switch scope {
        case .all:
            return true
        case .dms:
            return chat.chatType.isPrivate
        case .groups:
            return chat.chatType.isGroup
        }
    }
}
