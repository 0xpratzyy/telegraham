import Foundation

/// Protocol that all AI providers (Claude, OpenAI, etc.) conform to.
protocol AIProvider {
    /// Summarize a group's recent activity in 1-2 lines.
    func summarize(messages: [MessageSnippet], prompt: String) async throws -> String

    /// Semantic search: find chats relevant to a topic/concept.
    func semanticSearch(query: String, messages: [MessageSnippet]) async throws -> [SemanticSearchResultDTO]

    /// Agentic search: rank candidate chats for actionability against the exact query.
    func agenticSearch(
        query: String,
        constraints: AgenticSearchConstraintsDTO,
        candidates: [AgenticCandidateDTO]
    ) async throws -> [AgenticSearchResultDTO]

    /// Generate a follow-up suggestion for a single chat conversation.
    /// Returns (isRelevant, suggestedAction). If not relevant, the chat should be removed from pipeline.
    func generateFollowUpSuggestion(chatTitle: String, messages: [MessageSnippet]) async throws -> (Bool, String)

    /// Categorize a conversation for the Pipeline view (on_me / on_them / quiet).
    func categorizePipelineChat(context: PipelineChatContext, messages: [MessageSnippet]) async throws -> PipelineCategoryDTO

    /// Validates the API key by making a minimal request.
    func testConnection() async throws -> Bool
}

// MARK: - DTOs for AI response parsing

/// Wire format for follow-up suggestion returned by AI.
struct FollowUpSuggestionDTO: Codable {
    let relevant: Bool?
    let suggestedAction: String
}

/// Wire format for semantic search results returned by AI.
struct SemanticSearchResultDTO: Codable {
    let chatId: Int64
    let chatName: String
    let reason: String
    let relevance: String
    let matchingMessages: [String]?

    enum CodingKeys: String, CodingKey {
        case chatId
        case chatName
        case reason
        case relevance
        case matchingMessages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let numericId = try? container.decode(Int64.self, forKey: .chatId) {
            chatId = numericId
        } else {
            let rawId = try container.decode(String.self, forKey: .chatId)
            guard let numericId = Int64(rawId) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .chatId,
                    in: container,
                    debugDescription: "chatId must decode to an Int64"
                )
            }
            chatId = numericId
        }

        chatName = try container.decode(String.self, forKey: .chatName)
        reason = try container.decode(String.self, forKey: .reason)
        relevance = try container.decode(String.self, forKey: .relevance)
        matchingMessages = try container.decodeIfPresent([String].self, forKey: .matchingMessages)
    }
}

/// Candidate chats passed to agentic search reranker.
struct AgenticCandidateDTO: Codable {
    let chatId: Int64
    let chatName: String
    let pipelineCategory: String
    let messages: [MessageSnippet]
}

/// Query constraints that must be respected by agentic ranking.
struct AgenticSearchConstraintsDTO: Codable {
    let scope: String
    let replyConstraint: String
    let startDateISO8601: String?
    let endDateISO8601: String?
    let timeRangeLabel: String?
    let parseConfidence: Double
    let unsupportedFragments: [String]
}

/// Wire format for agentic search ranking returned by AI.
struct AgenticSearchResultDTO: Codable {
    let chatId: Int64
    let score: Int
    let warmth: String
    let replyability: String
    let reason: String
    let suggestedAction: String
    let confidence: Double
    let supportingMessageIds: [Int64]

    enum CodingKeys: String, CodingKey {
        case chatId
        case score
        case warmth
        case replyability
        case reason
        case suggestedAction
        case confidence
        case supportingMessageIds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let numericId = try? container.decode(Int64.self, forKey: .chatId) {
            chatId = numericId
        } else {
            let rawId = try container.decode(String.self, forKey: .chatId)
            guard let numericId = Int64(rawId) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .chatId,
                    in: container,
                    debugDescription: "chatId must decode to an Int64"
                )
            }
            chatId = numericId
        }

        if let numericScore = try? container.decode(Int.self, forKey: .score) {
            score = max(0, min(100, numericScore))
        } else {
            let rawScore = try container.decode(String.self, forKey: .score)
            score = max(0, min(100, Int(rawScore) ?? 0))
        }

        warmth = try container.decode(String.self, forKey: .warmth)
        replyability = try container.decode(String.self, forKey: .replyability)
        reason = try container.decode(String.self, forKey: .reason)
        suggestedAction = try container.decode(String.self, forKey: .suggestedAction)
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0

        let rawIds = try container.decodeIfPresent([String].self, forKey: .supportingMessageIds)
        if let rawIds {
            supportingMessageIds = rawIds.compactMap(Int64.init)
        } else if let numericIds = try? container.decode([Int64].self, forKey: .supportingMessageIds) {
            supportingMessageIds = numericIds
        } else {
            supportingMessageIds = []
        }
    }
}

/// Context passed to AI for pipeline categorization.
struct PipelineChatContext {
    let chatTitle: String
    let chatType: String      // "DM", "Group", "Supergroup", "Channel"
    let unreadCount: Int
    let myName: String
    let myUsername: String?
}

/// Wire format for pipeline AI categorization.
struct PipelineCategoryDTO: Codable {
    let category: String       // "on_me", "on_them", "quiet"
    let relevant: Bool?        // kept optional for backward compat, no longer used
    let suggestedAction: String
    let confident: Bool?
}
