import Foundation

/// Protocol that all AI providers (Claude, OpenAI, etc.) conform to.
protocol AIProvider {
    /// Summarize a group's recent activity in 1-2 lines.
    func summarize(messages: [MessageSnippet], prompt: String) async throws -> String

    /// Classify a user query into an intent.
    func classify(query: String) async throws -> QueryIntent

    /// Categorize DM messages into buckets (Needs Reply, FYI, Resolved, Business).
    func categorize(messages: [MessageSnippet]) async throws -> [CategorizedMessageDTO]

    /// Generate prioritized action items from messages.
    func generateActionItems(messages: [MessageSnippet]) async throws -> [ActionItemDTO]

    /// Generate a daily or weekly digest.
    func generateDigest(messages: [MessageSnippet], period: DigestPeriod) async throws -> DigestResult

    /// Validates the API key by making a minimal request.
    func testConnection() async throws -> Bool
}

// MARK: - DTOs for AI response parsing

/// Wire format for categorized messages returned by AI.
struct CategorizedMessageDTO: Codable {
    let index: Int
    let category: String
    let reason: String
}

/// Wire format for action items returned by AI.
struct ActionItemDTO: Codable {
    let chatName: String
    let senderName: String
    let summary: String
    let suggestedAction: String
    let urgency: String
}
