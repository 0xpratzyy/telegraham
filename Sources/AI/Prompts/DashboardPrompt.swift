import Foundation

enum DashboardTopicPrompt {
    static let systemPrompt = """
    You identify the user's main recurring Telegram work themes.
    The user wants a compact dashboard taxonomy, not many one-off labels.

    Return exactly one JSON object:
    {
      "topics": [
        {
          "name": "First Dollar",
          "rationale": "Early revenue, customers, pricing, contracts, and getting paid.",
          "score": 0.93
        }
      ]
    }

    Rules:
    - Return at most \(AppConstants.Dashboard.maxTopicCount) topics.
    - Prefer durable operating themes over narrow keywords.
    - Use short, human labels: 1-3 words.
    - Do not include private identifiers, phone numbers, or message IDs in topic names.
    - If the evidence is thin, return fewer topics.
    """

    static func userMessage(snippets: [MessageSnippet]) -> String {
        var text = "Recent Telegram snippets:\n"
        for snippet in MessageSnippet.truncateToTokenBudget(snippets) {
            text += "[\(snippet.relativeTimestamp)] \(snippet.chatName) / \(snippet.senderFirstName): \(snippet.text)\n"
        }
        return text
    }
}

enum DashboardTaskPrompt {
    static let systemPrompt = """
    You extract durable tasks from Telegram messages for a BD/partnerships operator.
    Messages marked [ME] are from the user.

    Return exactly one JSON object:
    {
      "tasks": [
        {
          "stableFingerprint": "chat-123:contract-review:501",
          "title": "Review contract diff",
          "summary": "Akhil asked for a review before the next call.",
          "suggestedAction": "Reply after checking the diff.",
          "ownerName": "Me",
          "personName": "Akhil",
          "chatId": 123,
          "chatTitle": "Akhil",
          "topicName": "First Dollar",
          "priority": "high",
          "confidence": 0.88,
          "dueAtISO8601": null,
          "sourceMessages": [
            {
              "chatId": 123,
              "messageId": 501,
              "senderName": "Akhil",
              "text": "Can you review this?",
              "dateISO8601": "2026-04-24T10:00:00Z"
            }
          ]
        }
      ]
    }

    Rules:
    - Extract only real work tasks, asks, promises, deliverables, follow-ups, decisions needed, or explicit next steps that are owned by the user.
    - Do not extract tasks assigned to another named person unless a later message shows [ME] accepted that work.
    - Requests for the user to send or share a pitch deck, deck, doc, file, link, invoice, contract, screenshot, media, or another artifact are tasks when ownership points to the user.
    - Do not extract reply-only items. A quick confirmation, acknowledgement, answer, or scheduling reply belongs in Reply Queue, not Tasks.
    - In groups, be conservative: "can someone", "we need", "please send", or "need X" is not the user's task unless the context clearly points to [ME].
    - If [ME] asks someone else to do something, the next step is on that person; do not turn it into a task for [ME].
    - Do not include ambient discussion, FYIs, greetings, or closed loops.
    - Use one of the provided topic names when it fits; otherwise use "Uncategorized".
    - stableFingerprint must remain stable for the same task across refreshes. Use chat id, durable task wording, and strongest source message id.
    - sourceMessages must identify evidence by both chatId and messageId.
    - priority is "high", "medium", or "low".
    - Keep title and suggestedAction concise.
    """

    static func userMessage(
        chat: TGChat,
        topics: [DashboardTopic],
        snippets: [MessageSnippet]
    ) -> String {
        let topicLines = topics.isEmpty
            ? "- Uncategorized"
            : topics.map { "- \($0.name): \($0.rationale)" }.joined(separator: "\n")

        var text = """
        Chat:
        - chatId: \(chat.id)
        - chatTitle: \(chat.title)
        - chatType: \(chat.chatType.displayName)

        Available dashboard topics:
        \(topicLines)

        Messages in chronological order:

        """

        for snippet in MessageSnippet.truncateToTokenBudget(snippets, maxChars: 8000) {
            text += "[messageId: \(snippet.messageId)] [\(snippet.relativeTimestamp)] \(snippet.senderFirstName): \(snippet.text)\n"
        }

        return text
    }
}

enum DashboardTaskTriagePrompt {
    static let systemPrompt = """
    You triage Telegram chats before dashboard task extraction.
    Messages marked [ME] are from the user.

    Return exactly one JSON object:
    {
      "decisions": [
        {
          "chatId": 123,
          "route": "effort_task",
          "confidence": 0.88,
          "reason": "The user was asked to prepare a partner brief.",
          "supportingMessageIds": [501]
        }
      ]
    }

    Route rules:
    - "effort_task": the user likely owns real work that takes effort before/after replying: prepare, review, send, ship, fix, introduce, follow up with material, make a decision, or complete a deliverable.
      Requests to send or share a pitch deck, deck, doc, file, link, invoice, contract, screenshot, media, or another artifact are effort_task when owned by the user.
      Example: "Bro, can you please send me the pitch deck" is effort_task, not reply_queue.
    - "reply_queue": the user only owes a short response, acknowledgement, answer, scheduling reply, or quick check. These belong to the existing reply queue, not the task list.
    - "ignore": the task is assigned to someone else, is ambient discussion, is a closed loop, is FYI/status-only, or ownership is too unclear.

    Ownership rules:
    - Be conservative. Do not assign a task to the user unless the message context points to the user, [ME]'s own commitment, or a clear small-group ownership signal.
    - In groups, names/handles matter. If the ask is directed to someone else, use "ignore".
    - If there is direct ownership but the only needed action is a quick textual reply, use "reply_queue".
    - Do not create tasks for bots, channels, announcements, or generic chatter.
    - Return exactly one decision for every candidate chatId.
    """

    static func userMessage(candidates: [DashboardTaskTriageCandidateDTO]) -> String {
        var text = "Candidate chats:\n"

        for candidate in candidates {
            text += "\n---\n"
            text += "chatId: \(candidate.chatId)\n"
            text += "chatTitle: \(candidate.chatTitle)\n"
            text += "chatType: \(candidate.chatType)\n"
            text += "unreadCount: \(candidate.unreadCount)\n"
            if let memberCount = candidate.memberCount {
                text += "memberCount: \(memberCount)\n"
            }
            text += "Messages in chronological order:\n"
            for snippet in MessageSnippet.truncateToTokenBudget(candidate.messages, maxChars: 6000) {
                text += "[messageId: \(snippet.messageId)] [\(snippet.relativeTimestamp)] \(snippet.senderFirstName): \(snippet.text)\n"
            }
        }

        return text
    }
}
