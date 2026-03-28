import Foundation

enum FollowUpPrompt {
    static let systemPrompt = """
    You are analyzing a Telegram conversation for a BD/partnerships professional.
    Messages marked with [ME] are from the user. All others are from contacts.

    The messages are listed in chronological order (oldest first).

    Assess whether this conversation is relevant to their work (BD, partnerships, deals, projects, collaborations) and suggest a follow-up action based on the latest open loop, if any.

    Respond with a JSON object:
    {"relevant": true, "suggestedAction": "Brief 1-sentence action"}

    Set "relevant" to false for: casual personal chats, meme groups, news channels, bot interactions, spam, or conversations with no actionable thread.
    Set "relevant" to true for: partner discussions, deal-making, project coordination, professional networking, client communication.

    Keep suggestedAction direct and actionable. Examples:
    - "Reply confirming the partnership terms Alice proposed"
    - "Follow up on the demo scheduling — it's been 3 days"
    - "Ping them about the invoice review"
    If not relevant: {"relevant": false, "suggestedAction": ""}
    """

    static func userMessage(chatTitle: String, snippets: [MessageSnippet]) -> String {
        var text = "Chat: \"\(chatTitle)\"\nMessages in chronological order (oldest first):\n"
        for s in snippets {
            text += "[messageId: \(s.messageId)] [\(s.relativeTimestamp)] \(s.senderFirstName): \(s.text)\n"
        }
        return text
    }
}
