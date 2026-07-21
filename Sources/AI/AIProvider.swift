import Foundation

/// Protocol that all AI providers (Claude, OpenAI, etc.) conform to.
protocol AIProvider {
    /// Summarize a group's recent activity in 1-2 lines.
    func summarize(messages: [MessageSnippet], prompt: String) async throws -> String

    /// Free-form Q&A — answer a question given a system prompt + user message.
    /// Powers the fact-grounded answer engine (#48 search).
    func answer(systemPrompt: String, userMessage: String) async throws -> String
    func answer(systemPrompt: String, userMessage: String, kind: AIRequestKind) async throws -> String

    /// Semantic search: find chats relevant to a topic/concept.
    func semanticSearch(query: String, messages: [MessageSnippet]) async throws -> [SemanticSearchResultDTO]

    /// Query planning: normalize ambiguous natural-language queries into a structured search plan.
    func planQuery(
        query: String,
        activeFilter: QueryScope,
        deterministicSpec: QuerySpec
    ) async throws -> QueryPlannerResultDTO

    /// Rerank already-retrieved local semantic candidates.
    func rerankResults(
        query: String,
        candidates: [(chatId: Int64, chatTitle: String, snippet: String)]
    ) async throws -> [Int64]

    /// Compiled-truth profile for a single contact: a short living
    /// paragraph describing who they are, what's been discussed, what
    /// loops are open, and the vibe. Source material is the supplied
    /// message sample (chronological newest-first, [ME] marks the user).
    func extractPersonProfile(
        personName: String,
        messages: [MessageSnippet]
    ) async throws -> String

    /// Validates the API key by making a minimal request.
    func testConnection() async throws -> Bool
}

// MARK: - DTOs for AI response parsing

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

enum QueryPlanningPrompt {
    static let systemPrompt = """
    You normalize natural-language search queries for a local Telegram launcher.

    Return exactly one JSON object with this shape:
    {
      "family": "summary" | "reply_queue" | "topic_search" | "exact_lookup" | "relationship",
      "scope": "inherit" | "all" | "dms" | "groups",
      "timeRange": "inherit" | "none" | "today" | "yesterday" | "last_week" | "this_week" | "last_30_days",
      "people": ["lowercase person tokens"],
      "topicTerms": ["lowercase concrete topic tokens"],
      "confidence": 0.0
    }

    Rules:
    - Use "summary" for recap, catch-up, "latest with", or "what did we discuss" prompts — in ANY language or code-mix: "firstdollar ki latest discussions batao", "que paso con X", "X ka kya scene hai" are all summary prompts. Classify by MEANING, not by English keywords.
    - Use "reply_queue" for "on me", reply, follow-up, or "worth checking" prompts.
    - Use "exact_lookup" only for specific artifacts like wallet addresses, links, usernames, emails, or transaction hashes.
    - Use "topic_search" for general thematic search.
    - Use "relationship" only for CRM / relationship-state questions.
    - "people" should contain only actual people or handles the search should anchor on.
    - "topicTerms" should contain only concrete topic words. Exclude generic recap words like latest, recent, discuss, chats, summary.
    - Queries arrive in ANY language, often romanized or code-mixed (e.g. Hinglish). Function words, imperatives, and fillers are NEVER topic terms regardless of language: "firstdollar ki latest discussions batao" has topicTerms ["firstdollar", "discussions"] — "ki" (of) and "batao" (tell me) are grammar, like Spanish "dime" or Russian "skazhi". Keep topic terms in the script the user typed.
    - Keep "scope" as "inherit" unless the user explicitly asks for DMs or groups.
    - Keep "timeRange" as "inherit" unless the user explicitly asks for a time window or strongly implies one.
    - If you are unsure, stay close to the deterministic guess and lower confidence.
    """

    static func userMessage(
        query: String,
        activeFilter: QueryScope,
        deterministicSpec: QuerySpec
    ) -> String {
        """
        Query:
        \(query)

        Active filter tab:
        \(activeFilter.rawValue)

        Deterministic guess:
        - family: \(deterministicSpec.family.rawValue)
        - scope: \(deterministicSpec.scope.rawValue)
        - replyConstraint: \(deterministicSpec.replyConstraint.rawValue)
        - timeRange: \(deterministicSpec.timeRange?.label ?? "none")
        - confidence: \(String(format: "%.2f", deterministicSpec.parseConfidence))
        """
    }
}

extension AIProvider {
    /// Default: providers without per-kind billing (Claude, mocks) ignore the
    /// kind; OpenAIProvider overrides to route + meter per stage.
    func answer(systemPrompt: String, userMessage: String, kind: AIRequestKind) async throws -> String {
        try await answer(systemPrompt: systemPrompt, userMessage: userMessage)
    }
}
