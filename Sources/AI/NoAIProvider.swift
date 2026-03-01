import Foundation

/// Passthrough provider used when no AI API key is configured.
/// Returns empty/default results so the app degrades gracefully.
final class NoAIProvider: AIProvider {
    func summarize(messages: [MessageSnippet], prompt: String) async throws -> String {
        throw AIError.providerNotConfigured
    }

    func generateActionItems(messages: [MessageSnippet]) async throws -> [ActionItemDTO] {
        throw AIError.providerNotConfigured
    }

    func semanticSearch(query: String, messages: [MessageSnippet]) async throws -> [SemanticSearchResultDTO] {
        throw AIError.providerNotConfigured
    }

    func generateFollowUpSuggestion(chatTitle: String, messages: [MessageSnippet]) async throws -> (Bool, String) {
        return (true, "")
    }

    func testConnection() async throws -> Bool {
        throw AIError.providerNotConfigured
    }
}
