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

        switch spec.preferredEngine {
        case .messageLookup:
            return .messageSearch
        case .semanticRetrieval:
            return .semanticSearch
        case .replyTriage:
            return .agenticSearch
        case .summarize:
            return .summarySearch
        case .graphCRM:
            return .unsupported
        }
    }
}
