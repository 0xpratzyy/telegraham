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
    - Use the structured digest fields carefully.
    - For group chats, treat `groupOwnershipHint` as the main ownership signal.
    - Treat `weakLocalHeuristic` as noisy metadata only. It must not override direct ownership evidence.
    - If `groupOwnershipHint` is `mentioned_other_handle`, `closed_after_actionable`, `closed_no_actionable_ask`, `waiting_on_them`, or `no_clear_actionable_ask`, do not return `on_me` unless the snippets clearly show a newer direct ask aimed at the user.
    - If `latestActionableInboundMentionsHandles` is not `none`, assume the ask is aimed at those handles, not the user.
    - If `broadcastStyleLatestActionable` is true and `directSecondPersonLatestActionable` is false, default to `quiet` for groups.
    - If a later message says `thank you`, `got it`, `on it`, `fixing that right now`, or similar after the actionable ask, prefer `quiet` or `on_them`.
    - For private chats, preserve strong local reply candidates; do not downgrade them just because the latest inbound is short or casual.
    - Treat acknowledgements, reactions, celebrations, and thread-closing chatter as `quiet` unless a new ask appears.
    - A previous ask that has already been answered or superseded by later messages should not remain `on_me`.
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
        text += "Each candidate includes a structured ownership digest. Local heuristic fields are intentionally weak hints, not proof.\n"
        text += "\nCandidate chats:\n"

        for candidate in candidates {
            let digest = ownershipDigest(for: candidate)

            text += "\n---\n"
            text += "chatId: \(candidate.chatId)\n"
            text += "chatName: \(candidate.chatName)\n"
            text += "chatType: \(candidate.chatType)\n"
            text += "unreadCount: \(candidate.unreadCount)\n"
            if let memberCount = candidate.memberCount {
                text += "memberCount: \(memberCount)\n"
            }
            text += "weakLocalHeuristic: "
            text += "localSignal=\(candidate.localSignal) "
            text += "pipelineHint=\(candidate.pipelineHint) "
            text += "replyOwed=\(candidate.replyOwed) "
            text += "strictReplySignal=\(candidate.strictReplySignal) "
            text += "effectiveGroupReplySignal=\(candidate.effectiveGroupReplySignal)\n"
            text += "groupOwnershipHint: \(digest.groupOwnershipHint)\n"
            text += "latestSpeaker: \(digest.latestSpeaker)\n"
            text += "latestInboundSpeaker: \(digest.latestInboundSpeaker)\n"
            text += "latestOutboundExists: \(digest.latestOutboundExists)\n"
            text += "latestActionableInboundSpeaker: \(digest.latestActionableInboundSpeaker)\n"
            text += "latestActionableInboundMentionsHandles: \(digest.latestActionableInboundMentionsHandles)\n"
            text += "broadcastStyleLatestActionable: \(digest.broadcastStyleLatestActionable)\n"
            text += "directSecondPersonLatestActionable: \(digest.directSecondPersonLatestActionable)\n"
            text += "latestCommitmentFromMe: \(digest.latestCommitmentFromMe)\n"
            text += "latestInboundOwnsNextStep: \(digest.latestInboundOwnsNextStep)\n"
            text += "closureAfterLatestActionable: \(digest.closureAfterLatestActionable)\n"
            text += "latestActionableStillAfterMyReply: \(digest.latestActionableStillAfterMyReply)\n"
            if let latestActionableInboundText = digest.latestActionableInboundText {
                text += "latestActionableInboundText: \(latestActionableInboundText)\n"
            }
            if let latestCommitmentText = digest.latestCommitmentText {
                text += "latestCommitmentText: \(latestCommitmentText)\n"
            }
            if let latestClosureText = digest.latestClosureText {
                text += "latestClosureText: \(latestClosureText)\n"
            }
            text += "Key snippets:\n"

            for message in ownershipDigestSnippets(from: candidate.messages) {
                text += "[messageId: \(message.messageId)] [\(message.relativeTimestamp)] \(message.senderFirstName): \(message.text)\n"
            }
        }

        return text
    }

    private struct OwnershipDigest {
        let groupOwnershipHint: String
        let latestSpeaker: String
        let latestInboundSpeaker: String
        let latestOutboundExists: Bool
        let latestActionableInboundSpeaker: String
        let latestActionableInboundMentionsHandles: String
        let broadcastStyleLatestActionable: Bool
        let directSecondPersonLatestActionable: Bool
        let latestCommitmentFromMe: Bool
        let latestInboundOwnsNextStep: Bool
        let closureAfterLatestActionable: Bool
        let latestActionableStillAfterMyReply: Bool
        let latestActionableInboundText: String?
        let latestCommitmentText: String?
        let latestClosureText: String?
    }

    private static func ownershipDigest(for candidate: ReplyQueueCandidateDTO) -> OwnershipDigest {
        let messages = candidate.messages
        let latest = messages.last
        let latestInbound = messages.last { $0.senderFirstName != "[ME]" }
        let latestOutbound = messages.last { $0.senderFirstName == "[ME]" }
        let latestActionableInbound = messages.last {
            $0.senderFirstName != "[ME]" && looksActionable($0.text)
        }
        let latestCommitment = messages.last {
            $0.senderFirstName == "[ME]" && looksLikeCommitmentFromMe($0.text)
        }
        let latestClosure = messages.last {
            looksLikeClosure($0.text, fromMe: $0.senderFirstName == "[ME]")
                || inboundMessageImpliesContactOwnsNextStep($0.text)
        }

        let latestActionableMentions = extractHandleMentions(from: latestActionableInbound?.text)
        let latestActionableText = latestActionableInbound?.text ?? ""
        let latestActionableStillAfterMyReply = {
            guard let latestActionableInbound else { return false }
            guard let latestOutbound else { return true }
            return latestActionableInbound.messageId > latestOutbound.messageId
        }()
        let closureAfterLatestActionable = {
            guard let latestActionableInbound, let latestClosure else { return false }
            return latestClosure.messageId > latestActionableInbound.messageId
        }()
        let latestInboundOwnsNextStep = latestClosure.map { inboundMessageImpliesContactOwnsNextStep($0.text) } ?? false
        let ownershipHint = groupOwnershipHint(
            candidate: candidate,
            latestActionableInbound: latestActionableInbound,
            latestCommitment: latestCommitment,
            latestClosure: latestClosure,
            latestOutbound: latestOutbound,
            closureAfterLatestActionable: closureAfterLatestActionable,
            latestActionableStillAfterMyReply: latestActionableStillAfterMyReply,
            latestActionableMentions: latestActionableMentions
        )

        return OwnershipDigest(
            groupOwnershipHint: ownershipHint,
            latestSpeaker: latest?.senderFirstName ?? "none",
            latestInboundSpeaker: latestInbound?.senderFirstName ?? "none",
            latestOutboundExists: latestOutbound != nil,
            latestActionableInboundSpeaker: latestActionableInbound?.senderFirstName ?? "none",
            latestActionableInboundMentionsHandles: latestActionableMentions.isEmpty ? "none" : latestActionableMentions.joined(separator: ", "),
            broadcastStyleLatestActionable: looksBroadcastGroupAsk(latestActionableText),
            directSecondPersonLatestActionable: looksDirectSecondPersonAsk(latestActionableText),
            latestCommitmentFromMe: latestCommitment != nil,
            latestInboundOwnsNextStep: latestInboundOwnsNextStep,
            closureAfterLatestActionable: closureAfterLatestActionable,
            latestActionableStillAfterMyReply: latestActionableStillAfterMyReply,
            latestActionableInboundText: latestActionableInbound?.text,
            latestCommitmentText: latestCommitment?.text,
            latestClosureText: latestClosure?.text
        )
    }

    private static func groupOwnershipHint(
        candidate: ReplyQueueCandidateDTO,
        latestActionableInbound: MessageSnippet?,
        latestCommitment: MessageSnippet?,
        latestClosure: MessageSnippet?,
        latestOutbound: MessageSnippet?,
        closureAfterLatestActionable: Bool,
        latestActionableStillAfterMyReply: Bool,
        latestActionableMentions: [String]
    ) -> String {
        guard candidate.chatType == "group" else {
            return "direct_private_context"
        }

        guard let latestActionableInbound else {
            if latestClosure != nil {
                return "closed_no_actionable_ask"
            }
            return "no_clear_actionable_ask"
        }

        if !latestActionableMentions.isEmpty {
            return "mentioned_other_handle"
        }

        if looksBroadcastGroupAsk(latestActionableInbound.text), !looksDirectSecondPersonAsk(latestActionableInbound.text) {
            return "broadcast_group_question"
        }

        if closureAfterLatestActionable {
            return "closed_after_actionable"
        }

        if let latestClosure, inboundMessageImpliesContactOwnsNextStep(latestClosure.text) {
            return "waiting_on_them"
        }

        if let latestOutbound, latestOutbound.messageId > latestActionableInbound.messageId, !latestActionableStillAfterMyReply {
            return "waiting_on_them"
        }

        if latestCommitment != nil, !latestActionableStillAfterMyReply {
            return "user_already_committed_no_reopen"
        }

        if latestCommitment != nil, latestActionableStillAfterMyReply {
            return "newer_follow_up_after_user_commitment"
        }

        return "possible_user_owned_group_follow_up"
    }

    private static func ownershipDigestSnippets(from messages: [MessageSnippet]) -> [MessageSnippet] {
        guard !messages.isEmpty else { return [] }

        let latest = messages.last
        let latestInbound = messages.last { $0.senderFirstName != "[ME]" }
        let latestOutbound = messages.last { $0.senderFirstName == "[ME]" }
        let actionableIndex = messages.lastIndex {
            $0.senderFirstName != "[ME]" && looksActionable($0.text)
        }
        let latestActionable = actionableIndex.map { messages[$0] }
        let beforeActionable: MessageSnippet?
        if let actionableIndex, actionableIndex > messages.startIndex {
            beforeActionable = messages[messages.index(before: actionableIndex)]
        } else {
            beforeActionable = nil
        }
        let afterActionable: MessageSnippet?
        if let actionableIndex {
            let nextIndex = messages.index(after: actionableIndex)
            afterActionable = nextIndex < messages.endIndex ? messages[nextIndex] : nil
        } else {
            afterActionable = nil
        }
        let latestCommitment = messages.last {
            $0.senderFirstName == "[ME]" && looksLikeCommitmentFromMe($0.text)
        }
        let latestClosure = messages.last {
            looksLikeClosure($0.text, fromMe: $0.senderFirstName == "[ME]")
                || inboundMessageImpliesContactOwnsNextStep($0.text)
        }

        var picked: [MessageSnippet] = []
        var seen: Set<Int64> = []
        for message in [
            latest,
            latestActionable,
            beforeActionable,
            afterActionable,
            latestCommitment,
            latestInbound,
            latestOutbound,
            latestClosure
        ].compactMap({ $0 }) {
            if seen.insert(message.messageId).inserted {
                picked.append(message)
            }
        }
        return picked
    }

    private static func looksActionable(_ text: String) -> Bool {
        let compact = stripURLs(from: normalize(text))
        guard !compact.isEmpty else { return false }
        if compact.contains("?") { return true }

        let signals = [
            "please", "pls", "can you", "could you", "let me know", "share", "send",
            "update", "review", "check", "approve", "confirm", "eta", "join", "when",
            "what", "how", "where", "reply", "follow up", "follow-up", "look into",
            "take a look", "help", "thoughts", "status"
        ]
        return signals.contains(where: { compact.contains($0) })
    }

    private static func looksLikeClosure(_ text: String, fromMe: Bool) -> Bool {
        let compact = normalize(text)
        guard !compact.isEmpty else { return false }

        let closureSignals = [
            "done", "thanks", "thank you", "got it", "noted", "sounds good",
            "perfect", "resolved", "on it", "will do", "will share", "will send"
        ]

        if fromMe {
            return closureSignals.contains(where: { compact == $0 || compact.contains($0) })
        }

        let passiveSignals = [
            "works", "all good", "fine", "cool", "great", "awesome"
        ]
        return (closureSignals + passiveSignals).contains(where: { compact == $0 || compact.contains($0) })
    }

    private static func looksLikeCommitmentFromMe(_ text: String) -> Bool {
        let compact = normalize(text)
        guard !compact.isEmpty else { return false }

        let commitmentSignals = [
            "i ll", "i'll", "i will", "on it", "will do", "will share", "will send",
            "will check", "let me", "bhejta", "check karta", "i can", "will reply", "will update"
        ]
        return commitmentSignals.contains(where: { compact.contains($0) })
    }

    private static func inboundMessageImpliesContactOwnsNextStep(_ text: String) -> Bool {
        let compact = normalize(text)
        guard !compact.isEmpty else { return false }

        let exactSignals: Set<String> = [
            "on it", "will do", "i will", "i ll", "working on it",
            "let me do it", "let me check", "will share", "will send",
            "done", "completed", "fixing that right now"
        ]
        if exactSignals.contains(compact) {
            return true
        }

        let phraseSignals = [
            "on it", "will do", "i will", "i ll", "working on",
            "let me", "will share", "will send", "sending", "share soon",
            "taking a look", "fixing that", "i got this"
        ]
        return phraseSignals.contains(where: { compact.contains($0) })
    }

    private static func looksBroadcastGroupAsk(_ text: String) -> Bool {
        let compact = normalize(text)
        guard !compact.isEmpty else { return false }

        let broadcastSignals = [
            "hello guys", "hey guys", "guys", "anyone", "someone", "everyone",
            "folks", "team", "is there any opportunity", "can anyone", "who can",
            "who wants", "does anyone", "any dev", "any designer"
        ]
        return broadcastSignals.contains(where: { compact.contains($0) })
    }

    private static func looksDirectSecondPersonAsk(_ text: String) -> Bool {
        let compact = normalize(text)
        guard !compact.isEmpty else { return false }

        let directSignals = ["can you", "could you", "would you", "please", "let me know", "you", "your"]
        return directSignals.contains(where: { compact.contains($0) })
    }

    private static func extractHandleMentions(from rawText: String?) -> [String] {
        guard let rawText, !rawText.isEmpty else { return [] }
        guard let regex = try? NSRegularExpression(pattern: "@([A-Za-z0-9_]{3,})") else {
            return []
        }

        let nsRange = NSRange(rawText.startIndex..<rawText.endIndex, in: rawText)
        let matches = regex.matches(in: rawText, range: nsRange)

        let handles = matches.compactMap { match -> String? in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: rawText) else {
                return nil
            }
            return "@\(rawText[range].lowercased())"
        }

        return Array(Set(handles)).sorted()
    }

    private static func stripURLs(from text: String) -> String {
        text.replacingOccurrences(
            of: "https?://\\S+",
            with: " ",
            options: .regularExpression
        )
    }

    private static func normalize(_ text: String) -> String {
        text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}
