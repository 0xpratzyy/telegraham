import Foundation

enum QuerySummaryPrompt {
    static func systemPrompt(query: String, chatTitle: String) -> String {
        """
        You prepare a Telegram operator to reply quickly.
        The user asked: "\(query)".

        Focus only on the provided chat: "\(chatTitle)".

        Return a short answer in 2-4 bullet-style sentences covering:
        - the latest relevant topic or decision
        - any unresolved ask or next step
        - anything the user should remember before replying

        Rules:
        - Be concrete and concise.
        - Prefer decisions, asks, blockers, and next actions over general chatter.
        - If the messages are sparse, say that clearly.
        - Do not invent facts that are not in the provided messages.
        - Respond with plain text only, no markdown heading.
        """
    }
}
