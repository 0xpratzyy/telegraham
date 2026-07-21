import Foundation
import SwiftUI

// MARK: - Privacy-Safe Message Representation

/// A privacy-filtered message snippet safe to send to AI providers.
/// Contains only message ID, first name, text, relative timestamp, chat ID, and chat name.
/// Never includes phone numbers, user IDs, session tokens, or media files.
struct MessageSnippet: Codable, Sendable {
    let messageId: Int64
    let senderFirstName: String
    let text: String
    let relativeTimestamp: String
    let chatId: Int64
    let chatName: String
    /// The message's real timestamp — fact extraction stamps each fact's
    /// validFrom with its CITED message's date (the age of the ask), not the
    /// batch-newest date. Optional so older call sites stay source-compatible.
    var date: Date? = nil

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
                chatName: chatTitle ?? msg.chatTitle ?? "Unknown",
                date: msg.date
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

enum QueryIntent: String, Codable, Sendable {
    case messageSearch = "message_search"
    case semanticSearch = "semantic_search"
    case summarySearch = "summary_search"
    case unsupported = "unsupported"
}

enum QueryFamily: String, Codable, Sendable {
    case exactLookup = "exact_lookup"
    case topicSearch = "topic_search"
    case replyQueue = "reply_queue"
    case relationship = "relationship"
    case summary = "summary"

    /// THE single family→engine mapping. QueryInterpreter (deterministic
    /// parse, planner-skip, planner-error fallback) and QueryRouter
    /// (planner merge) both route through this — two hand-maintained
    /// copies once drifted only because the compiler happened to catch it.
    var preferredEngine: QueryEngine {
        switch self {
        case .exactLookup:
            return .messageLookup
        case .topicSearch:
            return .semanticRetrieval
        case .replyQueue:
            // Reply-queue questions are answered by the context layer's
            // open-loop facts (answer card + reply queue view) — local
            // semantic ranking surfaces the relevant chats underneath.
            return .semanticRetrieval
        case .relationship:
            return .graphCRM
        case .summary:
            return .summarize
        }
    }
}

extension QueryEngine {
    /// The runtime intent each engine executes under — the other half of
    /// the single routing table above.
    var runtimeMode: QueryIntent {
        switch self {
        case .messageLookup:
            return .messageSearch
        case .semanticRetrieval:
            return .semanticSearch
        case .summarize:
            return .summarySearch
        case .graphCRM:
            return .unsupported
        }
    }
}

enum QueryEngine: String, Codable, Sendable {
    case messageLookup = "message_lookup"
    case semanticRetrieval = "semantic_retrieval"
    case graphCRM = "graph_crm"
    case summarize = "summarize"
}

enum QueryScope: String, Codable, Sendable {
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

enum ReplyConstraint: String, Codable, Sendable {
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

struct QueryPlannerHints: Codable, Equatable, Sendable {
    let people: [String]
    let topicTerms: [String]
}

struct QueryPlannerResultDTO: Codable, Equatable, Sendable {
    let family: String
    let scope: String
    let timeRange: String
    let people: [String]
    let topicTerms: [String]
    let confidence: Double
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
    let plannerHints: QueryPlannerHints?

    init(
        rawQuery: String,
        mode: QueryIntent,
        family: QueryFamily,
        preferredEngine: QueryEngine,
        scope: QueryScope,
        scopeWasExplicit: Bool,
        replyConstraint: ReplyConstraint,
        timeRange: TimeRangeConstraint?,
        parseConfidence: Double,
        unsupportedFragments: [String],
        plannerHints: QueryPlannerHints? = nil
    ) {
        self.rawQuery = rawQuery
        self.mode = mode
        self.family = family
        self.preferredEngine = preferredEngine
        self.scope = scope
        self.scopeWasExplicit = scopeWasExplicit
        self.replyConstraint = replyConstraint
        self.timeRange = timeRange
        self.parseConfidence = parseConfidence
        self.unsupportedFragments = unsupportedFragments
        self.plannerHints = plannerHints
    }

    var hasActionableConstraints: Bool {
        scopeWasExplicit || replyConstraint != .none || timeRange != nil
    }

    /// A question ABOUT a person: the planner extracted people AND the query
    /// is phrased as more than a bare name. Single definition shared by the
    /// router (engine choice) and the launcher (auto-answer trigger) so the
    /// two can never disagree.
    static func isPersonQuestion(rawQuery: String, people: [String]) -> Bool {
        guard !people.isEmpty else { return false }
        return rawQuery.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count >= 3
    }

    var isPersonQuestion: Bool {
        Self.isPersonQuestion(rawQuery: rawQuery, people: plannerHints?.people ?? [])
    }

    /// THE single definition of "the Ask Pidgy answer engine owns this
    /// query" — shared by the router (which keeps these on local semantic
    /// ranking so the chat is the only summary surface) and the launcher's
    /// auto-open. Summary-family person questions and reply-queue questions
    /// qualify; a topic/lookup query that merely NAMES a person does not —
    /// the user asked for messages, not a recap, and auto-opening the chat
    /// would swallow their results.
    var isAnswerEngineQuestion: Bool {
        family == .replyQueue || (family == .summary && isPersonQuestion)
    }

    /// Copy with planner term hints attached — used when the planner's
    /// confidence is too low to reroute the query family but its term
    /// extraction is still better evidence than raw tokenization.
    func attachingPlannerHints(_ hints: QueryPlannerHints?) -> QuerySpec {
        guard let hints else { return self }
        return QuerySpec(
            rawQuery: rawQuery,
            mode: mode,
            family: family,
            preferredEngine: preferredEngine,
            scope: scope,
            scopeWasExplicit: scopeWasExplicit,
            replyConstraint: replyConstraint,
            timeRange: timeRange,
            parseConfidence: parseConfidence,
            unsupportedFragments: unsupportedFragments,
            plannerHints: hints
        )
    }

}

struct SearchRoutingSnapshot: Identifiable {
    let query: String
    let spec: QuerySpec
    let runtimeIntent: QueryIntent

    var id: String { query }
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
            case .high: return Color.Pidgy.avPurple
            case .medium: return Color.Pidgy.accent
            }
        }
    }
}

// MARK: - AI Configuration

struct AIProviderConfig {
    let providerType: ProviderType
    let apiKey: String
    let model: String
    /// BYOK custom OpenAI-compatible endpoint (Gemini/xAI/Groq/OpenRouter/
    /// custom). nil → the provider's default (api.openai.com for `.openai`).
    var baseURL: URL? = nil

    enum ProviderType: String, CaseIterable, Sendable {
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
    /// Rate limited (429/503) after the provider's in-call backoff already
    /// exhausted its retries. Distinct from `.httpError` so the outer
    /// `RetryHelper` treats it as terminal and does NOT retry on top of that
    /// backoff (which previously stacked to ~45s of blocked time).
    case rateLimited(retryAfter: TimeInterval?)
    case networkError(Error)
    case parsingError(String)
    case providerNotConfigured

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "No API key configured"
        case .invalidResponse: return "Invalid response from AI provider"
        case .httpError(let code, let msg): return "HTTP \(code): \(msg)"
        case .rateLimited(let retryAfter):
            return retryAfter.map { "Rate limited (retry after \(Int($0))s)" } ?? "Rate limited"
        case .networkError(let err): return "Network error: \(err.localizedDescription)"
        case .parsingError(let detail): return "Failed to parse AI response: \(detail)"
        case .providerNotConfigured: return "AI provider not configured"
        }
    }
}
