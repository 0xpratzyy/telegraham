import Foundation

/// Routes user queries: AI-powered semantic search if configured, keyword fallback otherwise.
@MainActor
final class QueryRouter: ObservableObject {
    private var aiProvider: AIProvider

    init(aiProvider: AIProvider) {
        self.aiProvider = aiProvider
    }

    func updateProvider(_ provider: AIProvider) {
        self.aiProvider = provider
    }

    func route(query: String) async -> QueryIntent {
        // If AI is configured → semantic search (go through chats, ask AI)
        // If no AI → keyword search via TDLib
        if !(aiProvider is NoAIProvider) {
            return .semanticSearch
        }
        return .messageSearch
    }
}
