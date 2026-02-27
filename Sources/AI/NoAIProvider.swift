import Foundation

/// Passthrough provider used when no AI API key is configured.
/// Returns empty/default results so the app degrades gracefully.
final class NoAIProvider: AIProvider {
    func summarize(messages: [MessageSnippet], prompt: String) async throws -> String {
        throw AIError.providerNotConfigured
    }

    func classify(query: String) async throws -> QueryIntent {
        return .messageSearch
    }

    func categorize(messages: [MessageSnippet]) async throws -> [CategorizedMessageDTO] {
        throw AIError.providerNotConfigured
    }

    func generateActionItems(messages: [MessageSnippet]) async throws -> [ActionItemDTO] {
        throw AIError.providerNotConfigured
    }

    func generateDigest(messages: [MessageSnippet], period: DigestPeriod) async throws -> DigestResult {
        throw AIError.providerNotConfigured
    }
}
