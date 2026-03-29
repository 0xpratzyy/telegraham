import Foundation

/// Routes user queries: AI-powered semantic search if configured, keyword fallback otherwise.
@MainActor
final class QueryRouter: ObservableObject {
    private var aiProvider: AIProvider
    private let queryInterpreter: QueryInterpreting

    init(aiProvider: AIProvider, queryInterpreter: QueryInterpreting = QueryInterpreter()) {
        self.aiProvider = aiProvider
        self.queryInterpreter = queryInterpreter
    }

    func updateProvider(_ provider: AIProvider) {
        self.aiProvider = provider
    }

    func route(
        query: String,
        querySpec: QuerySpec? = nil,
        activeFilter: QueryScope = .all,
        timezone: TimeZone = .current,
        now: Date = Date()
    ) async -> QueryIntent {
        guard !(aiProvider is NoAIProvider) else { return .messageSearch }

        let normalized = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return .semanticSearch }

        let spec = querySpec ?? queryInterpreter.parse(
            query: query,
            now: now,
            timezone: timezone,
            activeFilter: activeFilter
        )
        if spec.mode == .agenticSearch || spec.hasActionableConstraints {
            return .agenticSearch
        }

        let agenticPhrases = [
            "intro",
            "connect",
            "partner",
            "ecosystem",
            "warm",
            "lead",
            "reply",
            "replied",
            "respond",
            "follow up",
            "follow-up",
            "who should i",
            "who do i",
            "waiting on me",
            "haven't replied",
            "have not replied",
            "first dollar"
        ]

        if agenticPhrases.contains(where: { normalized.contains($0) }) {
            return .agenticSearch
        }
        return .semanticSearch
    }
}
