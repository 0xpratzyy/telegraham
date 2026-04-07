import Foundation
import SwiftUI

// MARK: - Privacy-Safe Message Representation

/// A privacy-filtered message snippet safe to send to AI providers.
/// Contains only message ID, first name, text, relative timestamp, chat ID, and chat name.
/// Never includes phone numbers, user IDs, session tokens, or media files.
struct MessageSnippet: Codable {
    let messageId: Int64
    let senderFirstName: String
    let text: String
    let relativeTimestamp: String
    let chatId: Int64
    let chatName: String

    static func fromMessages(_ messages: [TGMessage], chatTitle: String? = nil) -> [MessageSnippet] {
        messages.compactMap { msg in
            guard let text = msg.textContent, !text.isEmpty else { return nil }
            let firstName = msg.senderName?.split(separator: " ").first.map(String.init) ?? "Unknown"
            return MessageSnippet(
                messageId: msg.id,
                senderFirstName: firstName,
                text: text,
                relativeTimestamp: msg.relativeDate,
                chatId: msg.chatId,
                chatName: chatTitle ?? msg.chatTitle ?? "Unknown"
            )
        }
    }

    /// Truncate an array of snippets to stay within ~4000 tokens (~16000 chars).
    static func truncateToTokenBudget(_ snippets: [MessageSnippet], maxChars: Int = AppConstants.AI.maxTokenBudgetChars) -> [MessageSnippet] {
        var totalChars = 0
        var result: [MessageSnippet] = []
        for snippet in snippets {
            let snippetChars =
                String(snippet.messageId).count +
                snippet.senderFirstName.count +
                snippet.text.count +
                snippet.relativeTimestamp.count +
                String(snippet.chatId).count +
                snippet.chatName.count + 20
            if totalChars + snippetChars > maxChars { break }
            totalChars += snippetChars
            result.append(snippet)
        }
        return result
    }
}

// MARK: - Query Intent

enum QueryIntent: String, Codable {
    case messageSearch = "message_search"
    case semanticSearch = "semantic_search"
    case agenticSearch = "agentic_search"
    case summarySearch = "summary_search"
    case unsupported = "unsupported"
}

enum QueryFamily: String, Codable {
    case exactLookup = "exact_lookup"
    case topicSearch = "topic_search"
    case replyQueue = "reply_queue"
    case relationship = "relationship"
    case summary = "summary"
}

enum QueryEngine: String, Codable {
    case messageLookup = "message_lookup"
    case semanticRetrieval = "semantic_retrieval"
    case replyTriage = "reply_triage"
    case graphCRM = "graph_crm"
    case summarize = "summarize"
}

enum QueryScope: String, Codable {
    case all
    case dms
    case groups

    var label: String {
        switch self {
        case .all: return "All"
        case .dms: return "DMs"
        case .groups: return "Groups"
        }
    }
}

enum ReplyConstraint: String, Codable {
    case none
    case pipelineOnMeOnly = "pipeline_on_me_only"
}

struct TimeRangeConstraint: Codable {
    let startDate: Date
    let endDate: Date
    let label: String

    func contains(_ date: Date) -> Bool {
        date >= startDate && date <= endDate
    }
}

struct QuerySpec: Codable {
    let rawQuery: String
    let mode: QueryIntent
    let family: QueryFamily
    let preferredEngine: QueryEngine
    let scope: QueryScope
    let scopeWasExplicit: Bool
    let replyConstraint: ReplyConstraint
    let timeRange: TimeRangeConstraint?
    let parseConfidence: Double
    let unsupportedFragments: [String]

    var hasActionableConstraints: Bool {
        scopeWasExplicit || replyConstraint != .none || timeRange != nil
    }

    var requiresExhaustiveChatReview: Bool {
        preferredEngine == .replyTriage
    }
}

struct SearchRoutingSnapshot: Identifiable {
    let query: String
    let spec: QuerySpec
    let runtimeIntent: QueryIntent

    var id: String { query }
}

struct AgenticSearchCandidate {
    let chat: TGChat
    let pipelineCategory: String
    let strictReplySignal: Bool
    let messages: [TGMessage]
}

// MARK: - Semantic Search

struct SemanticSearchResult: Identifiable {
    let chatId: Int64
    let chatTitle: String
    let reason: String
    let relevance: Relevance
    let matchingMessages: [String]

    var id: Int64 { chatId }

    enum Relevance: String {
        case high, medium

        var color: Color {
            switch self {
            case .high: return .purple
            case .medium: return .blue
            }
        }
    }
}

struct AgenticSearchResult: Identifiable {
    let chatId: Int64
    let chatTitle: String
    let score: Int
    let warmth: Warmth
    let replyability: Replyability
    let reason: String
    let suggestedAction: String
    let confidence: Double
    let supportingMessageIds: [Int64]

    var id: Int64 { chatId }

    enum Warmth: String {
        case hot, warm, cold

        var color: Color {
            switch self {
            case .hot: return .red
            case .warm: return .orange
            case .cold: return .blue
            }
        }
    }

    enum Replyability: String {
        case replyNow = "reply_now"
        case waitingOnThem = "waiting_on_them"
        case unclear

        var label: String {
            switch self {
            case .replyNow: return "REPLY NOW"
            case .waitingOnThem: return "WAITING"
            case .unclear: return "UNCLEAR"
            }
        }

        var color: Color {
            switch self {
            case .replyNow: return .green
            case .waitingOnThem: return .blue
            case .unclear: return .gray
            }
        }
    }
}

// MARK: - AI Configuration

struct AIProviderConfig {
    let providerType: ProviderType
    let apiKey: String
    let model: String

    enum ProviderType: String, CaseIterable {
        case claude = "Claude"
        case openai = "OpenAI"
        case none = "None"

        var defaultModel: String {
            switch self {
            case .claude: return AppConstants.AI.defaultClaudeModel
            case .openai: return AppConstants.AI.defaultOpenAIModel
            case .none: return ""
            }
        }
    }
}

// MARK: - Errors

enum AIError: LocalizedError {
    case noAPIKey
    case invalidResponse
    case httpError(Int, String)
    case networkError(Error)
    case parsingError(String)
    case providerNotConfigured

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "No API key configured"
        case .invalidResponse: return "Invalid response from AI provider"
        case .httpError(let code, let msg): return "HTTP \(code): \(msg)"
        case .networkError(let err): return "Network error: \(err.localizedDescription)"
        case .parsingError(let detail): return "Failed to parse AI response: \(detail)"
        case .providerNotConfigured: return "AI provider not configured"
        }
    }
}
