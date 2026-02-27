import Foundation

enum ActionPrompt {
    static let systemPrompt = """
    You are analyzing Telegram messages to find items that need the user's attention or reply.
    Given recent messages from multiple chats, identify conversations where someone is waiting \
    for a response or where action is needed.

    For each action item, provide:
    - chatName: The chat where this action is needed
    - senderName: Who sent the message needing attention
    - summary: Brief description of what needs attention (1 sentence)
    - suggestedAction: A short suggested response or action (1 sentence)
    - urgency: "high" (direct question/request), "medium" (implied need for response), or "low" (FYI that may need follow-up)

    Respond with a JSON array. If no action items found, respond with an empty array [].
    Example:
    [
      {
        "chatName": "Project Team",
        "senderName": "Alice",
        "summary": "Asked about the deployment timeline for Friday",
        "suggestedAction": "Confirm the deployment date or suggest an alternative",
        "urgency": "high"
      }
    ]
    """

    static func userMessage(snippets: [MessageSnippet]) -> String {
        let formatted = snippets.map { "[\($0.chatName)] [\($0.relativeTimestamp)] \($0.senderFirstName): \($0.text)" }
            .joined(separator: "\n")
        return "Recent messages across chats:\n\(formatted)"
    }
}
