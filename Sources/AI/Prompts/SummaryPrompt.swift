import Foundation

enum SummaryPrompt {
    static let systemPrompt = """
    You are a concise summarizer for a Telegram chat. Given recent messages from a group chat, \
    produce a 1-2 line activity summary describing what's happening in the group.

    Rules:
    - Be concise: maximum 2 short sentences
    - Focus on topics being discussed, not individual messages
    - Use present tense ("Discussing X", "Planning Y")
    - Do not mention specific user names
    - If messages are sparse or trivial, say "Quiet recently" or similar
    - Respond with ONLY the summary text, no labels or prefixes
    """

    static func userMessage(snippets: [MessageSnippet]) -> String {
        let formatted = snippets.map { "[\($0.relativeTimestamp)] \($0.senderFirstName): \($0.text)" }
            .joined(separator: "\n")
        return "Recent messages:\n\(formatted)"
    }
}
