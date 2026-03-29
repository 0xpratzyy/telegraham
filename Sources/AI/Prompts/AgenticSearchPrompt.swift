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
    - Keep scores calibrated 0-100 and confidence 0.0-1.0.
    - Hard constraints are mandatory. Never return chats that violate scope, reply constraint, or time range.

    Return a JSON array sorted by score DESC.
    Every result must map to an input candidate chatId.
    Use this schema exactly:
    [
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
            text += "Messages (oldest first):\n"

            for message in candidate.messages {
                text += "[messageId: \(message.messageId)] [\(message.relativeTimestamp)] \(message.senderFirstName): \(message.text)\n"
            }
        }

        return text
    }
}
