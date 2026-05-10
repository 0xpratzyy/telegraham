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
        // Preserve chat order — first appearance wins. Grouping per-chat is
        // important once we send multi-chat digests: without it the AI
        // sees a flat stream of "Akhil: ..." with no clue which message
        // came from which conversation.
        var chatOrder: [Int64] = []
        var snippetsByChat: [Int64: [MessageSnippet]] = [:]
        for snippet in snippets {
            if snippetsByChat[snippet.chatId] == nil {
                chatOrder.append(snippet.chatId)
                snippetsByChat[snippet.chatId] = []
            }
            snippetsByChat[snippet.chatId]?.append(snippet)
        }

        if chatOrder.count <= 1 {
            let formatted = snippets.map { "[\($0.relativeTimestamp)] \($0.senderFirstName): \($0.text)" }
                .joined(separator: "\n")
            return "Recent messages:\n\(formatted)"
        }

        var sections: [String] = []
        for chatId in chatOrder {
            guard let chatSnippets = snippetsByChat[chatId],
                  let first = chatSnippets.first
            else { continue }
            var section = "=== Chat: \(first.chatName) ===\n"
            section += chatSnippets
                .map { "[\($0.relativeTimestamp)] \($0.senderFirstName): \($0.text)" }
                .joined(separator: "\n")
            sections.append(section)
        }
        return "Recent messages across \(chatOrder.count) chats:\n\n" + sections.joined(separator: "\n\n")
    }
}
