import Foundation

/// Protocol that all AI providers (Claude, OpenAI, etc.) conform to.
protocol AIProvider {
    /// Summarize a group's recent activity in 1-2 lines.
    func summarize(messages: [MessageSnippet], prompt: String) async throws -> String

    /// Generate prioritized action items from messages (used by Priority tab).
    func generateActionItems(messages: [MessageSnippet]) async throws -> [ActionItemDTO]

    /// Semantic search: find chats relevant to a topic/concept.
    func semanticSearch(query: String, messages: [MessageSnippet]) async throws -> [SemanticSearchResultDTO]

    /// Generate a follow-up suggestion for a single chat conversation.
    /// Returns (isRelevant, suggestedAction). If not relevant, the chat should be removed from pipeline.
    func generateFollowUpSuggestion(chatTitle: String, messages: [MessageSnippet]) async throws -> (Bool, String)

    /// Categorize a conversation for the Pipeline view (on_me / on_them / quiet).
    func categorizePipelineChat(context: PipelineChatContext, messages: [MessageSnippet]) async throws -> PipelineCategoryDTO

    /// Validates the API key by making a minimal request.
    func testConnection() async throws -> Bool
}

// MARK: - DTOs for AI response parsing

/// Wire format for action items returned by AI.
struct ActionItemDTO: Codable {
    let chatName: String
    let senderName: String
    let summary: String
    let suggestedAction: String
    let urgency: String
}

/// Wire format for follow-up suggestion returned by AI.
struct FollowUpSuggestionDTO: Codable {
    let relevant: Bool?
    let suggestedAction: String
}

/// Wire format for semantic search results returned by AI.
struct SemanticSearchResultDTO: Codable {
    let chatName: String
    let reason: String
    let relevance: String
    let matchingMessages: [String]?
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
