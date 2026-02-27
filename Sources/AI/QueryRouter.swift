import Foundation

/// Routes user queries to the appropriate intent using pattern matching first,
/// then falling back to AI classification if no pattern matches.
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
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Pattern matching — no AI call needed
        if matchesGroupDiscovery(q) { return .groupDiscovery }
        if matchesActionItems(q) { return .actionItems }
        if matchesDigest(q) { return .digest }
        if matchesMessageSearch(q) { return .messageSearch }
        if matchesDMIntelligence(q) { return .dmIntelligence }

        // AI fallback — only if a real provider is configured
        if !(aiProvider is NoAIProvider) {
            do {
                return try await aiProvider.classify(query: q)
            } catch {
                print("[QueryRouter] AI classification failed, falling back to search: \(error)")
            }
        }

        return .messageSearch
    }

    // MARK: - Pattern Matchers

    private func matchesGroupDiscovery(_ q: String) -> Bool {
        let patterns = ["show all groups", "show groups", "my groups", "list groups", "browse groups", "channels"]
        if patterns.contains(where: { q.contains($0) }) { return true }
        if q.range(of: #"^(show\s+)?(all\s+)?groups?$"#, options: .regularExpression) != nil { return true }
        return false
    }

    private func matchesActionItems(_ q: String) -> Bool {
        let patterns = ["who needs reply", "who needs a reply", "needs reply", "waiting on me",
                        "pending", "unanswered", "action items", "what should i reply"]
        return patterns.contains(where: { q.contains($0) })
    }

    private func matchesDigest(_ q: String) -> Bool {
        let patterns = ["digest", "summary", "summarize", "recap", "catch up",
                        "what did i miss", "weekly digest", "daily digest", "weekly summary", "daily summary"]
        return patterns.contains(where: { q.contains($0) })
    }

    private func matchesMessageSearch(_ q: String) -> Bool {
        return q.hasPrefix("search:")
    }

    private func matchesDMIntelligence(_ q: String) -> Bool {
        let patterns = ["unread dm", "unread dms", "direct message", "my dms",
                        "recent dm", "recent dms", "private chat", "personal messages"]
        return patterns.contains(where: { q.contains($0) })
    }
}
