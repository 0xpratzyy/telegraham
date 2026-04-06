import Foundation

enum AgenticSearchPrompt {
    static let systemPrompt = """
    You are ranking Telegram chats for a BD/ecosystem operator who gets high message volume.
    Goal: prioritize which chats are warm and actionable for the exact query.

    Input format:
    - Each candidate includes chatId, chatName, pipelineCategory, and recent messages.
    - Messages are listed oldest to newest.
    - Each message includes a stable messageId.
    - Messages marked [ME] are from the user.

    Ranking guidance:
    - Prioritize clear open loops, intros/partner asks, and high-likelihood next actions.
    - Treat pipelineCategory="on_me" as a positive signal for replyability.
    - Penalize closed threads, stale chatter, and unclear asks.
    - When replyConstraint="pipeline_on_me_only", interpret the query as a strict reply queue, not a generic warm-leads search.
    - For strict reply-queue queries, heavily prefer targeted unresolved asks and direct obligations.
    - Penalize ambient group chatter, broad community discussion, and untargeted updates.
    - In groups, only use replyability="reply_now" when the unresolved ask is clearly aimed at [ME] or [ME] is the obvious next owner.
    - Prefer DMs over groups when actionability is otherwise similar.
    - Keep scores calibrated 0-100 and confidence 0.0-1.0.
    - Hard constraints are mandatory. Never return chats that violate scope, reply constraint, or time range.

    Return exactly one JSON object sorted by score DESC.
    You MUST return exactly one result object for every candidate chatId provided below.
    Do not omit candidates, even weak ones.
    If a candidate should not be in the real reply queue, still include it with a low score and replyability="unclear" or "waiting_on_them".
    Every result must map to an input candidate chatId.
    Do not wrap the response in markdown.
    Use this schema exactly:
    {
      "results": [
        {
          "chatId": 123,
          "score": 92,
          "warmth": "hot",
          "replyability": "reply_now",
          "reason": "Contact asked for an intro and followed up yesterday.",
          "suggestedAction": "Reply with two intro options and ask for preferred context.",
          "confidence": 0.86,
          "supportingMessageIds": [555, 556]
        }
      ]
    }

    Valid warmth values: "hot", "warm", "cold"
    Valid replyability values: "reply_now", "waiting_on_them", "unclear"
    """

    static func userMessage(
        query: String,
        constraints: AgenticSearchConstraintsDTO,
        candidates: [AgenticCandidateDTO]
    ) -> String {
        var text = "User query: \"\(query)\"\n\n"
        text += "Hard constraints:\n"
        text += "- scope: \(constraints.scope)\n"
        text += "- replyConstraint: \(constraints.replyConstraint)\n"
        if let start = constraints.startDateISO8601, let end = constraints.endDateISO8601 {
            text += "- timeRange: \(start) to \(end)\n"
        } else {
            text += "- timeRange: none\n"
        }
        if let label = constraints.timeRangeLabel, !label.isEmpty {
            text += "- timeRangeLabel: \(label)\n"
        }
        text += "- parseConfidence: \(String(format: "%.2f", constraints.parseConfidence))\n"
        if !constraints.unsupportedFragments.isEmpty {
            text += "- partiallyUnsupported: \(constraints.unsupportedFragments.joined(separator: "; "))\n"
        }

        text += "\nCandidate chats:\n"

        for candidate in candidates {
            text += "\n---\n"
            text += "chatId: \(candidate.chatId)\n"
            text += "chatName: \(candidate.chatName)\n"
            text += "pipelineCategory: \(candidate.pipelineCategory)\n"
            text += "strictReplySignal: \(candidate.strictReplySignal)\n"
            text += "Messages (oldest first):\n"

            for message in candidate.messages {
                text += "[messageId: \(message.messageId)] [\(message.relativeTimestamp)] \(message.senderFirstName): \(message.text)\n"
            }
        }

        return text
    }
}
