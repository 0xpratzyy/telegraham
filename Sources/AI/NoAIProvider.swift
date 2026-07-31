import Foundation

/// Passthrough provider used when no AI API key is configured.
/// Returns empty/default results so the app degrades gracefully.
final class NoAIProvider: AIProvider {
    func summarize(messages: [MessageSnippet], prompt: String) async throws -> String {
        throw AIError.providerNotConfigured
    }

    func answer(systemPrompt: String, userMessage: String) async throws -> String {
        throw AIError.providerNotConfigured
    }

    func semanticSearch(query: String, messages: [MessageSnippet]) async throws -> [SemanticSearchResultDTO] {
        throw AIError.providerNotConfigured
    }

    func planQuery(
        query: String,
        activeFilter: QueryScope,
        deterministicSpec: QuerySpec
    ) async throws -> QueryPlannerResultDTO {
        throw AIError.providerNotConfigured
    }

    func extractPersonProfile(
        personName: String,
        messages: [MessageSnippet]
    ) async throws -> String {
        throw AIError.providerNotConfigured
    }

    func testConnection() async throws -> Bool {
        throw AIError.providerNotConfigured
    }
}
