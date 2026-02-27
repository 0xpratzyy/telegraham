import Foundation

enum CategorizationPrompt {
    static let systemPrompt = """
    You are categorizing Telegram direct messages into four buckets to help the user prioritize.

    Categories:
    - Needs Reply: Messages with direct questions, requests, or conversations waiting for a response
    - FYI: Informational messages, links, updates that don't require a response
    - Resolved: Conversations that appear concluded (thanks, confirmations, closings)
    - Business: Work-related, professional, or transactional messages

    For each message (identified by index), provide:
    - index: The message index (0-based)
    - category: One of "Needs Reply", "FYI", "Resolved", "Business"
    - reason: Brief explanation of why this category (1 short sentence)

    Respond with a JSON array:
    [
      {"index": 0, "category": "Needs Reply", "reason": "Direct question about meeting time"},
      {"index": 1, "category": "FYI", "reason": "Shared a news article link"}
    ]
    """

    static func userMessage(snippets: [MessageSnippet]) -> String {
        let formatted = snippets.enumerated().map { idx, s in
            "[\(idx)] [\(s.chatName)] \(s.senderFirstName): \(s.text)"
        }.joined(separator: "\n")
        return "Categorize these DM messages:\n\(formatted)"
    }
}
