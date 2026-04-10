import Foundation

enum ReplyQueueTriagePrompt {
    static let systemPrompt = """
    You triage Telegram chats for a BD/community operator.
    Your job is to decide whether the user currently owes a reply in each candidate chat.

    You will receive many candidate chats at once. Return exactly one result for every candidate chatId.

    Classification rules:
    - "on_me": the user clearly owes a reply or follow-up now.
    - "on_them": the other side owns the next step, or the user already replied and is waiting.
    - "quiet": no active obligation right now.
    - "need_more": only use when the provided context is genuinely insufficient to tell.

    Key judgment rules:
    - Prefer concrete unresolved asks over vague warmth.
    - The sender label "[ME]" means the current user sent that message.
    - In groups, do NOT mark "on_me" if the ask is clearly aimed at someone else.
    - Treat acknowledgements, reactions, celebrations, and thread-closing chatter as "quiet" unless a new ask appears.
    - A previous ask that has already been answered or superseded by later messages should not remain "on_me".
    - Use supportingMessageIds to point at the messages that justify the decision.
    - suggestedAction should be short and practical.

    Return exactly one JSON object:
    {
      "results": [
        {
          "chatId": 123,
          "classification": "on_me",
          "urgency": "high",
          "reason": "Contact asked for an update and has not received one yet.",
          "suggestedAction": "Reply with a status update and expected timing.",
          "confidence": 0.87,
          "supportingMessageIds": [111, 112]
        }
      ]
    }

    Valid classification values: "on_me", "on_them", "quiet", "need_more"
    Valid urgency values: "high", "medium", "low"
    """

    static func userMessage(
        query: String,
        scope: QueryScope,
        candidates: [ReplyQueueCandidateDTO]
    ) -> String {
        var text = "User query: \"\(query)\"\n"
        text += "Scope: \(scope.rawValue)\n"
        text += "Return one result for every candidate chatId.\n"
        text += "Each candidate includes a compact local digest and only the most relevant recent snippets.\n"
        text += "\nCandidate chats:\n"

        for candidate in candidates {
            text += "\n---\n"
            text += "chatId: \(candidate.chatId)\n"
            text += "chatName: \(candidate.chatName)\n"
            text += "chatType: \(candidate.chatType)\n"
            text += "unreadCount: \(candidate.unreadCount)\n"
            if let memberCount = candidate.memberCount {
                text += "memberCount: \(memberCount)\n"
            }
            text += "localSignal: \(candidate.localSignal)\n"
            text += "pipelineHint: \(candidate.pipelineHint)\n"
            text += "replyOwed: \(candidate.replyOwed)\n"
            text += "strictReplySignal: \(candidate.strictReplySignal)\n"
            text += "effectiveGroupReplySignal: \(candidate.effectiveGroupReplySignal)\n"
            text += "Key snippets:\n"

            for message in compactSnippets(from: candidate.messages) {
                text += "[messageId: \(message.messageId)] [\(message.relativeTimestamp)] \(message.senderFirstName): \(message.text)\n"
            }
        }

        return text
    }

    private static func compactSnippets(from messages: [MessageSnippet]) -> [MessageSnippet] {
        guard !messages.isEmpty else { return [] }

        let latest = messages.last
        let inbound = messages.last { $0.senderFirstName != "[ME]" }
        let outbound = messages.last { $0.senderFirstName == "[ME]" }

        var picked: [MessageSnippet] = []
        var seen: Set<Int64> = []
        for message in [latest, inbound, outbound].compactMap({ $0 }) {
            if seen.insert(message.messageId).inserted {
                picked.append(message)
            }
        }
        return picked
    }
}
