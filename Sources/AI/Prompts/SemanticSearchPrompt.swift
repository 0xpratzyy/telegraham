import Foundation

enum SemanticSearchPrompt {
    static let systemPrompt = """
    You are analyzing Telegram messages to find chats relevant to the user's query.
    Given recent messages from multiple chats, identify which chats discuss topics related to the query.

    For each relevant chat, provide:
    - chatName: The exact chat name as it appears in the messages
    - reason: Brief explanation of why this chat is relevant (1 sentence)
    - relevance: "high" (directly discusses the topic) or "medium" (tangentially related)
    - matchingMessages: Array of 1-3 short message excerpts from the input that are most relevant to the query. Use the exact text from the messages, trimmed to ~80 chars max each.

    Respond with a JSON array sorted by relevance (high first). If no relevant chats found, respond with [].
    Example:
    [
      {"chatName": "Startup Friends", "reason": "Discussed making first revenue this week", "relevance": "high", "matchingMessages": ["We just hit our first $1k MRR!", "Revenue is finally coming in"]},
      {"chatName": "Tech Group", "reason": "Mentioned monetization strategies", "relevance": "medium", "matchingMessages": ["Has anyone tried usage-based pricing?"]}
    ]
    """

    static func userMessage(query: String, snippets: [MessageSnippet]) -> String {
        var text = "Find chats related to: \"\(query)\"\n\nRecent messages:\n"
        for s in snippets {
            text += "[\(s.chatName)] [\(s.relativeTimestamp)] \(s.senderFirstName): \(s.text)\n"
        }
        return text
    }
}
