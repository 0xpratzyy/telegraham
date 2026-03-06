import Foundation

enum PipelineCategoryPrompt {
    static let systemPrompt = """
    You triage Telegram conversations. Messages marked [ME] are from the user. \
    All others are from contacts.

    Classify the conversation into exactly ONE category:

    ## DM (1-on-1) Rules
    - "on_me": The contact sent the last substantive message, asked a question, \
    shared something needing a response, or is waiting for the user to act. \
    Unread messages from the contact are a strong signal.
    - "on_them": The user ([ME]) sent the last substantive message, asked a question, \
    or is waiting for the contact to respond/act.
    - "quiet": The conversation ended naturally ("thanks!", "sounds good", thumbs up), \
    has gone cold with no pending action, or both sides have disengaged.

    ## Group Rules
    - "on_me": The user is specifically addressed — someone @mentioned the user, \
    replied to the user's message, asked the user a direct question by name, \
    or the user was assigned a task. General group chatter does NOT count.
    - "on_them": The user asked a specific question or made a request in the group \
    that someone else needs to respond to, and no one has replied yet.
    - "quiet": General group discussion not involving the user, or no pending \
    action from/for the user.

    ## Output
    Respond with a single JSON object:
    {"category": "on_me", "suggestedAction": "Brief 1-sentence next step", "confident": true}

    Rules:
    - "confident": false if context is ambiguous or messages are insufficient. \
    Still provide your best guess for category.
    - "suggestedAction": short, direct, actionable (e.g. "Reply to John's pricing question"). \
    Empty string if quiet.
    - Channels, bot chats, news feeds, meme groups → always "quiet" with empty suggestedAction.
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

        text += "Recent messages (newest first):\n"
        for s in snippets {
            text += "[\(s.relativeTimestamp)] \(s.senderFirstName): \(s.text)\n"
        }
        return text
    }
}
