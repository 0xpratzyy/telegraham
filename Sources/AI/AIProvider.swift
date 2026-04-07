import Foundation

/// Protocol that all AI providers (Claude, OpenAI, etc.) conform to.
protocol AIProvider {
    /// Summarize a group's recent activity in 1-2 lines.
    func summarize(messages: [MessageSnippet], prompt: String) async throws -> String

    /// Semantic search: find chats relevant to a topic/concept.
    func semanticSearch(query: String, messages: [MessageSnippet]) async throws -> [SemanticSearchResultDTO]

    /// Rerank already-retrieved local semantic candidates.
    func rerankResults(
        query: String,
        candidates: [(chatId: Int64, chatTitle: String, snippet: String)]
    ) async throws -> [Int64]

    /// Agentic search: rank candidate chats for actionability against the exact query.
    func agenticSearch(
        query: String,
        constraints: AgenticSearchConstraintsDTO,
        candidates: [AgenticCandidateDTO]
    ) async throws -> [AgenticSearchResultDTO]

    /// Reply queue triage: classify many chats at once into on_me / on_them / quiet / need_more.
    func triageReplyQueue(
        query: String,
        scope: QueryScope,
        candidates: [ReplyQueueCandidateDTO]
    ) async throws -> [ReplyQueueTriageResultDTO]

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

struct SearchRerankResultDTO: Codable {
    let rankedChatIds: [Int64]

    enum CodingKeys: String, CodingKey {
        case rankedChatIds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let numericIds = try? container.decode([Int64].self, forKey: .rankedChatIds) {
            rankedChatIds = numericIds
            return
        }

        if let rawIds = try? container.decode([String].self, forKey: .rankedChatIds) {
            rankedChatIds = rawIds.compactMap(Int64.init)
            return
        }

        rankedChatIds = []
    }
}

enum SearchRerankPrompt {
    static let systemPrompt = """
    You rerank Telegram chat search candidates.
    The local search engine already found plausible chats. Your job is only to order them by relevance to the exact query.

    Rules:
    - Use only the provided candidates.
    - Prefer candidates whose snippet directly answers the query intent.
    - Prefer concrete topic matches over vague thematic overlap.
    - Keep the ranking stable and practical for the user opening the next chat.
    - Do not invent chat IDs.

    Return exactly one JSON object:
    {
      "rankedChatIds": [123, 456, 789]
    }
    """

    static func userMessage(
        query: String,
        candidates: [(chatId: Int64, chatTitle: String, snippet: String)]
    ) -> String {
        let renderedCandidates = candidates.map { candidate in
            """
            - chatId: \(candidate.chatId)
              chatTitle: \(candidate.chatTitle)
              snippet: \(candidate.snippet)
            """
        }.joined(separator: "\n")

        return """
        Query:
        \(query)

        Candidates:
        \(renderedCandidates)
        """
    }
}

/// Candidate chats passed to agentic search reranker.
struct AgenticCandidateDTO: Codable {
    let chatId: Int64
    let chatName: String
    let pipelineCategory: String
    let strictReplySignal: Bool
    let messages: [MessageSnippet]
}

struct ReplyQueueCandidateDTO: Codable {
    let chatId: Int64
    let chatName: String
    let chatType: String
    let unreadCount: Int
    let memberCount: Int?
    let localSignal: String
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

        let rawIds = try? container.decodeIfPresent([String].self, forKey: .supportingMessageIds)
        if let rawIds {
            supportingMessageIds = rawIds.compactMap(Int64.init)
        } else if let numericIds = try? container.decode([Int64].self, forKey: .supportingMessageIds) {
            supportingMessageIds = numericIds
        } else {
            supportingMessageIds = []
        }
    }
}

struct AgenticSearchResultsEnvelope: Codable {
    let results: [AgenticSearchResultDTO]
}

enum AgenticSearchResultParser {
    static func parse(_ response: String) throws -> [AgenticSearchResultDTO] {
        if let envelope: AgenticSearchResultsEnvelope = try? JSONExtractor.parseJSON(response) {
            return envelope.results
        }
        let bareArray: [AgenticSearchResultDTO] = try JSONExtractor.parseJSON(response)
        return bareArray
    }
}

struct ReplyQueueTriageResultDTO: Codable {
    let chatId: Int64
    let classification: String
    let urgency: String
    let reason: String
    let suggestedAction: String
    let confidence: Double
    let supportingMessageIds: [Int64]

    init(
        chatId: Int64,
        classification: String,
        urgency: String,
        reason: String,
        suggestedAction: String,
        confidence: Double,
        supportingMessageIds: [Int64]
    ) {
        self.chatId = chatId
        self.classification = classification
        self.urgency = urgency
        self.reason = reason
        self.suggestedAction = suggestedAction
        self.confidence = confidence
        self.supportingMessageIds = supportingMessageIds
    }

    enum CodingKeys: String, CodingKey {
        case chatId
        case classification
        case urgency
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

        classification = try container.decode(String.self, forKey: .classification)
        urgency = try container.decode(String.self, forKey: .urgency)
        reason = try container.decode(String.self, forKey: .reason)
        suggestedAction = try container.decode(String.self, forKey: .suggestedAction)
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0

        let rawIds = try? container.decodeIfPresent([String].self, forKey: .supportingMessageIds)
        if let rawIds {
            supportingMessageIds = rawIds.compactMap(Int64.init)
        } else if let numericIds = try? container.decode([Int64].self, forKey: .supportingMessageIds) {
            supportingMessageIds = numericIds
        } else {
            supportingMessageIds = []
        }
    }
}

struct ReplyQueueTriageResultsEnvelope: Codable {
    let results: [ReplyQueueTriageResultDTO]
}

enum ReplyQueueTriageResultParser {
    static func parse(_ response: String) throws -> [ReplyQueueTriageResultDTO] {
        if let envelope: ReplyQueueTriageResultsEnvelope = try? JSONExtractor.parseJSON(response) {
            return envelope.results
        }
        let bareArray: [ReplyQueueTriageResultDTO] = try JSONExtractor.parseJSON(response)
        return bareArray
    }
}

/// Context passed to AI for pipeline categorization.
struct PipelineChatContext {
    let chatTitle: String
    let chatType: String      // "DM", "Group", "Supergroup", "Channel"
    let unreadCount: Int
    let memberCount: Int?
    let myName: String
    let myUsername: String?
}

/// Wire format for pipeline AI categorization.
struct PipelineCategoryDTO: Codable {
    let status: String?         // "decision" | "need_more"
    let category: String?       // "on_me", "on_them", "quiet" (decision)
    let urgency: String?        // "high" | "low" (decision)
    let suggestedAction: String // may be empty string
    let reason: String?         // need_more reason
    let additionalMessages: Int? // need_more message ask
    let relevant: Bool?         // backward compat, no longer used
    let confident: Bool?        // backward compat

    init(
        status: String? = nil,
        category: String? = nil,
        urgency: String? = nil,
        suggestedAction: String = "",
        reason: String? = nil,
        additionalMessages: Int? = nil,
        relevant: Bool? = nil,
        confident: Bool? = nil
    ) {
        self.status = status
        self.category = category
        self.urgency = urgency
        self.suggestedAction = suggestedAction
        self.reason = reason
        self.additionalMessages = additionalMessages
        self.relevant = relevant
        self.confident = confident
    }

    enum CodingKeys: String, CodingKey {
        case status
        case category
        case urgency
        case suggestedAction
        case reason
        case additionalMessages
        case relevant
        case confident
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        urgency = try container.decodeIfPresent(String.self, forKey: .urgency)
        suggestedAction = try container.decodeIfPresent(String.self, forKey: .suggestedAction) ?? ""
        reason = try container.decodeIfPresent(String.self, forKey: .reason)

        if let intCount = try? container.decode(Int.self, forKey: .additionalMessages) {
            additionalMessages = intCount
        } else if let stringCount = try? container.decode(String.self, forKey: .additionalMessages),
                  let intCount = Int(stringCount) {
            additionalMessages = intCount
        } else {
            additionalMessages = nil
        }

        relevant = try container.decodeIfPresent(Bool.self, forKey: .relevant)
        confident = try container.decodeIfPresent(Bool.self, forKey: .confident)
    }
}
