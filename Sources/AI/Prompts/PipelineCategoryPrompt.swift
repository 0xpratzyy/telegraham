import Foundation

enum PipelineCategoryPrompt {
    static let systemPrompt = """
    You triage Telegram conversations. Messages marked [ME] are from the user. \
    All others are from contacts.

    The messages are listed in chronological order (oldest first). \
    Reason step by step through the timeline and decide who currently owes the next meaningful response.

    Definitions:
    - A substantive message is a question, request, proposal, assignment, follow-up, or update that creates a next step.
    - A closed thread is a natural ending such as "thanks", "sounds good", emoji acknowledgment, or a discussion with no open loop.
    - Use recency heavily, but earlier messages matter if they establish who is waiting on whom.

    Classify the conversation into exactly ONE category:

    ## DM (1-on-1) Rules
    - "on_me": The contact sent the latest substantive message, is waiting on the user, or followed up on something the user owes.
    - "on_them": The user ([ME]) sent the latest substantive message and is waiting on the contact to reply or act.
    - "quiet": The thread is closed, stale with no pending obligation, or does not clearly leave anyone waiting.

    ## Group Rules
    - "on_me": The user is directly addressed, @mentioned, assigned a task, or clearly the expected responder.
    - "on_them": The user asked a specific question or made a concrete request and the group has not answered yet.
    - "quiet": General discussion, side chatter, or anything that does not clearly leave an obligation on either side.

    Rules:
    - If context is ambiguous or insufficient, set "confident" to false but still provide the best category.
    - "suggestedAction" must be short, direct, and actionable. Use empty string for quiet.
    - Channels, bot chats, news feeds, meme groups, and broadcast-style chats are always "quiet".
    - Do not over-index on unread count if the latest substantive turn clearly indicates the opposite responsibility.

    Respond with a single JSON object:
    {"category": "on_me", "suggestedAction": "Brief 1-sentence next step", "confident": true}
    """

    static func userMessage(context: PipelineChatContext, snippets: [MessageSnippet]) -> String {
        var text = "Chat: \"\(context.chatTitle)\" (\(context.chatType)"
        if context.unreadCount > 0 {
            text += ", \(context.unreadCount) unread"
        }
        text += ")\n"

        var identity = "You are: \(context.myName)"
        if let username = context.myUsername {
            identity += " (@\(username))"
        }
        text += identity + "\n\n"

        text += "Messages in chronological order (oldest first):\n"
        for s in snippets {
            text += "[messageId: \(s.messageId)] [\(s.relativeTimestamp)] \(s.senderFirstName): \(s.text)\n"
        }
        return text
    }
}
