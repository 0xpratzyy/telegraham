import Foundation

enum ReplyQueueTriagePrompt {
    static let systemPrompt = """
    You triage Telegram chats for a BD/community operator.
    Your job is to decide whether the user currently owes a reply in each candidate chat.

    You will receive many candidate chats at once. Return exactly one result for every candidate chatId.

    Classification rules:
    - "on_me": the user clearly owes a reply or follow-up now.
    - "worth_checking": there is a real open loop worth surfacing in a secondary bucket, but it is not strong or fresh enough to claim as a primary reply-now item.
    - "on_them": the other side owns the next step, or the user already replied and is waiting.
    - "quiet": no active obligation right now.
    - "need_more": only use when the provided context is genuinely insufficient to tell.

    Key judgment rules:
    - Reply Queue is only for conversational replies. If the user's next step is to send or share a pitch deck, deck, doc, file, link, invoice, contract, screenshot, media, or another artifact, classify it as "quiet" because dashboard Tasks should own artifact delivery.
    - Example: "Bro, can you please send me the pitch deck" is "quiet" for Reply Queue, not "on_me"; it belongs in Tasks.
    - Use "worth_checking" for stale or diluted open loops: someone did ask the user something, but later discussion, age, or ambiguous ownership makes it too weak for "on_me".
    - In groups, prefer "worth_checking" over "on_me" when an older request is still somewhat relevant but there is no fresh direct ask on the user now.
    - Treat acknowledgements, reactions, celebrations, and thread-closing chatter as "quiet" unless a new ask appears.
    - If the other side clearly owns the next step, use "on_them", not "worth_checking".
    - Treat `groupOwnershipHint` as the main ownership signal for groups.
    - If `latestActionableLooksExplanatory` is true in a group, default to `quiet` unless another field shows a separate explicit ask.
    - If `earlierRequestForInputExists` is true but the later context is more of a task dump, status list, or cc-style update than a fresh direct ask, prefer `worth_checking` over `on_me`.
    - If `groupOwnershipHint` is `mentioned_other_handle` only because `ccStyleHandleMentions` is true, that is weak negative evidence, not an automatic rejection.
    - If a newer direct ask clearly lands on the user, use `on_me`, not `worth_checking`.
    - If the loop is obviously stale, diffuse, or buried under later discussion but still plausibly relevant, use `worth_checking`.
    - If someone else later says `got it`, `fixing that right now`, `on it`, `working on it`, `already added`, or similar, prefer `quiet` or `on_them`, not `worth_checking`.
    - For private chats, use `privateOwnershipHint` as a strong cue. Use `worth_checking` for older private follow-ups that still matter but are no longer strong enough for reply-now.
    - Use supportingMessageIds to point at the messages that justify the decision.
    - suggestedAction should be short and practical.

    Return exactly one JSON object:
    {
      "results": [
        {
          "chatId": 123,
          "classification": "worth_checking",
          "urgency": "medium",
          "reason": "There was an earlier request for your input, but it is no longer fresh enough to count as reply-now.",
          "suggestedAction": "Review the thread and decide if a follow-up is still useful.",
          "confidence": 0.74,
          "supportingMessageIds": [111, 112]
        }
      ]
    }

    Valid classification values: "on_me", "worth_checking", "on_them", "quiet", "need_more"
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
        text += "Each candidate includes structured ownership fields plus a wider group context window to separate ambient technical discussion from real reply obligations.\n"
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
            if let privateOwnershipHint = digest.privateOwnershipHint {
                text += "privateOwnershipHint: \(privateOwnershipHint)\n"
                text += "privateReplySignal: "
                text += "localSignal=\(candidate.localSignal) "
                text += "replyOwed=\(candidate.replyOwed) "
                text += "strictReplySignal=\(candidate.strictReplySignal)\n"
            }
            text += "latestSpeaker: \(digest.latestSpeaker)\n"
            text += "latestInboundSpeaker: \(digest.latestInboundSpeaker)\n"
            text += "latestOutboundExists: \(digest.latestOutboundExists)\n"
            text += "latestActionableInboundSpeaker: \(digest.latestActionableInboundSpeaker)\n"
            text += "latestActionableInboundMentionsHandles: \(digest.latestActionableInboundMentionsHandles)\n"
            if candidate.chatType == "group" {
                text += "broadcastStyleLatestActionable: \(digest.broadcastStyleLatestActionable)\n"
                text += "directSecondPersonLatestActionable: \(digest.directSecondPersonLatestActionable)\n"
                text += "explicitSecondPersonLatestActionable: \(digest.explicitSecondPersonLatestActionable)\n"
                text += "latestActionableLooksExplanatory: \(digest.latestActionableLooksExplanatory)\n"
                text += "ccStyleHandleMentions: \(digest.ccStyleHandleMentions)\n"
                text += "earlierRequestForInputExists: \(digest.earlierRequestForInputExists)\n"
            }
            text += "latestCommitmentFromMe: \(digest.latestCommitmentFromMe)\n"
            text += "latestInboundOwnsNextStep: \(digest.latestInboundOwnsNextStep)\n"
            text += "closureAfterLatestActionable: \(digest.closureAfterLatestActionable)\n"
            text += "latestActionableStillAfterMyReply: \(digest.latestActionableStillAfterMyReply)\n"
            if candidate.chatType == "group", let earlierRequestForInputText = digest.earlierRequestForInputText {
                text += "earlierRequestForInputText: \(earlierRequestForInputText)\n"
            }
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

            for message in ownershipDigestSnippets(from: candidate.messages, chatType: candidate.chatType) {
                text += "[messageId: \(message.messageId)] [\(message.relativeTimestamp)] \(message.senderFirstName): \(message.text)\n"
            }
        }

        return text
    }

    private struct OwnershipDigest {
        let groupOwnershipHint: String
        let privateOwnershipHint: String?
        let latestSpeaker: String
        let latestInboundSpeaker: String
        let latestOutboundExists: Bool
        let latestActionableInboundSpeaker: String
        let latestActionableInboundMentionsHandles: String
        let broadcastStyleLatestActionable: Bool
        let directSecondPersonLatestActionable: Bool
        let explicitSecondPersonLatestActionable: Bool
        let latestActionableLooksExplanatory: Bool
        let ccStyleHandleMentions: Bool
        let earlierRequestForInputExists: Bool
        let latestCommitmentFromMe: Bool
        let latestInboundOwnsNextStep: Bool
        let closureAfterLatestActionable: Bool
        let latestActionableStillAfterMyReply: Bool
        let earlierRequestForInputText: String?
        let latestActionableInboundText: String?
        let latestCommitmentText: String?
        let latestClosureText: String?
    }

    private static func ownershipDigest(for candidate: ReplyQueueCandidateDTO) -> OwnershipDigest {
        let messages = candidate.messages
        let latest = messages.last
        let latestInbound = messages.last { $0.senderFirstName != "[ME]" }
        let latestOutbound = messages.last { $0.senderFirstName == "[ME]" }
        let actionableIndex = messages.lastIndex {
            isDigestActionableInbound($0, chatType: candidate.chatType)
        }
        let latestActionableInbound = actionableIndex.map { messages[$0] }
        let latestCommitment = messages.last {
            $0.senderFirstName == "[ME]" && looksLikeCommitmentFromMe($0.text)
        }
        let latestClosure = messages.last {
            looksLikeClosure($0.text, fromMe: $0.senderFirstName == "[ME]")
                || inboundMessageImpliesContactOwnsNextStep($0.text)
        }
        let latestActionableMentions = extractHandleMentions(from: latestActionableInbound?.text)
        let latestActionableText = latestActionableInbound?.text ?? ""
        let earlierRequestForInput = latestEarlierRequestForInput(messages, actionableIndex: actionableIndex)

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

        let groupOwnershipHint = groupOwnershipHint(
            candidate: candidate,
            latestActionableInbound: latestActionableInbound,
            latestCommitment: latestCommitment,
            latestClosure: latestClosure,
            latestOutbound: latestOutbound,
            closureAfterLatestActionable: closureAfterLatestActionable,
            latestActionableStillAfterMyReply: latestActionableStillAfterMyReply,
            latestActionableMentions: latestActionableMentions
        )

        let privateOwnershipHint = candidate.chatType == "group"
            ? nil
            : privateOwnershipHint(
                latestActionableInbound: latestActionableInbound,
                latestCommitment: latestCommitment,
                latestClosure: latestClosure,
                latestOutbound: latestOutbound,
                closureAfterLatestActionable: closureAfterLatestActionable,
                latestActionableStillAfterMyReply: latestActionableStillAfterMyReply
            )

        return OwnershipDigest(
            groupOwnershipHint: groupOwnershipHint,
            privateOwnershipHint: privateOwnershipHint,
            latestSpeaker: latest?.senderFirstName ?? "none",
            latestInboundSpeaker: latestInbound?.senderFirstName ?? "none",
            latestOutboundExists: latestOutbound != nil,
            latestActionableInboundSpeaker: latestActionableInbound?.senderFirstName ?? "none",
            latestActionableInboundMentionsHandles: latestActionableMentions.isEmpty ? "none" : latestActionableMentions.joined(separator: ", "),
            broadcastStyleLatestActionable: looksBroadcastGroupAsk(latestActionableText),
            directSecondPersonLatestActionable: looksDirectSecondPersonAsk(latestActionableText),
            explicitSecondPersonLatestActionable: looksDirectSecondPersonAsk(latestActionableText),
            latestActionableLooksExplanatory: looksExplanatoryGroupReply(latestActionableText),
            ccStyleHandleMentions: looksCCStyleMentions(latestActionableText),
            earlierRequestForInputExists: earlierRequestForInput != nil,
            latestCommitmentFromMe: latestCommitment != nil,
            latestInboundOwnsNextStep: latestInboundOwnsNextStep,
            closureAfterLatestActionable: closureAfterLatestActionable,
            latestActionableStillAfterMyReply: latestActionableStillAfterMyReply,
            earlierRequestForInputText: earlierRequestForInput?.text,
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

    private static func privateOwnershipHint(
        latestActionableInbound: MessageSnippet?,
        latestCommitment: MessageSnippet?,
        latestClosure: MessageSnippet?,
        latestOutbound: MessageSnippet?,
        closureAfterLatestActionable: Bool,
        latestActionableStillAfterMyReply: Bool
    ) -> String {
        if latestActionableInbound == nil {
            return latestClosure != nil ? "private_closed" : "private_unclear"
        }
        if closureAfterLatestActionable {
            return "private_closed"
        }
        if let latestActionableInbound,
           let latestOutbound,
           latestOutbound.messageId > latestActionableInbound.messageId,
           !latestActionableStillAfterMyReply {
            return "private_waiting_on_them"
        }
        if latestCommitment != nil, !latestActionableStillAfterMyReply {
            return "private_waiting_on_them"
        }
        if latestActionableStillAfterMyReply || latestCommitment != nil {
            return "private_direct_follow_up"
        }
        return "private_unclear"
    }

    private static func ownershipDigestSnippets(from messages: [MessageSnippet], chatType: String) -> [MessageSnippet] {
        guard !messages.isEmpty else { return [] }
        if chatType == "group" {
            return pickDigestV6GroupSnippets(from: messages)
        }
        return pickDigestV5PrivateSnippets(from: messages)
    }

    private static func pickDigestV6GroupSnippets(from messages: [MessageSnippet]) -> [MessageSnippet] {
        let latest = messages.last
        let latestInbound = messages.last { $0.senderFirstName != "[ME]" }
        let latestOutbound = messages.last { $0.senderFirstName == "[ME]" }
        let actionableIndex = messages.lastIndex {
            isDigestActionableInbound($0, chatType: "group")
        }
        let latestActionable = actionableIndex.map { messages[$0] }
        let earlierRequestForInput = latestEarlierRequestForInput(messages, actionableIndex: actionableIndex)
        let contextBefore: [MessageSnippet]
        if let actionableIndex {
            let start = max(messages.startIndex, actionableIndex - 3)
            contextBefore = Array(messages[start..<actionableIndex])
        } else {
            contextBefore = []
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
        for message in [latest, latestActionable, earlierRequestForInput]
            .compactMap({ $0 }) + contextBefore.reversed() + [latestCommitment, latestInbound, latestOutbound, latestClosure].compactMap({ $0 }) {
            if seen.insert(message.messageId).inserted {
                picked.append(message)
            }
        }
        return picked
    }

    private static func pickDigestV5PrivateSnippets(from messages: [MessageSnippet]) -> [MessageSnippet] {
        guard !messages.isEmpty else { return [] }

        let actionableIndex = messages.lastIndex {
            isDigestActionableInbound($0, chatType: "private")
        }

        var picked: [MessageSnippet] = []
        var seen: Set<Int64> = []

        if let actionableIndex {
            let start = max(messages.startIndex, actionableIndex - 2)
            let end = min(messages.endIndex, actionableIndex + 3)
            for message in [messages.last].compactMap({ $0 }) + Array(messages[start..<end]) {
                if seen.insert(message.messageId).inserted {
                    picked.append(message)
                }
            }
            return picked
        }

        for message in messages.suffix(3) {
            if seen.insert(message.messageId).inserted {
                picked.append(message)
            }
        }
        return picked
    }

    private static func latestEarlierRequestForInput(
        _ messages: [MessageSnippet],
        actionableIndex: Int?
    ) -> MessageSnippet? {
        guard let actionableIndex else { return nil }
        for index in stride(from: actionableIndex - 1, through: 0, by: -1) {
            let message = messages[index]
            if message.senderFirstName == "[ME]" {
                continue
            }
            if looksRequestForInput(message.text) {
                return message
            }
        }
        return nil
    }

    private static func isDigestActionableInbound(_ message: MessageSnippet, chatType: String) -> Bool {
        guard message.senderFirstName != "[ME]" else { return false }
        if looksActionable(message.text) {
            return true
        }
        if chatType == "group" && looksGroupTaskDumpFollowUp(message.text) {
            return true
        }
        return false
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
            "perfect", "resolved", "on it", "will do", "will share", "will send",
            "already added", "added it", "handled", "taken care of"
        ]

        if fromMe {
            return closureSignals.contains(where: { compact == $0 || compact.contains($0) })
        }

        let passiveSignals = ["works", "all good", "fine", "cool", "great", "awesome"]
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
            "done", "completed", "fixing that right now", "already added", "added it"
        ]
        if exactSignals.contains(compact) {
            return true
        }

        let phraseSignals = [
            "on it", "will do", "i will", "i ll", "working on",
            "let me", "will share", "will send", "sending", "share soon",
            "taking a look", "take a look", "fixing that", "i got this",
            "already added", "added it", "handled", "taken care of"
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

        let directSignals = [
            "can you", "could you", "would you", "will you", "please", "let me know",
            "do you", "are you", "you should", "you need to", "kindly"
        ]
        return directSignals.contains(where: { compact.contains($0) })
    }

    private static func looksRequestForInput(_ text: String) -> Bool {
        let compact = normalize(text)
        guard !compact.isEmpty else { return false }

        let signals = [
            "give more input", "gib more input", "need input", "your input",
            "share feedback", "feedback", "thoughts", "what do you think",
            "let me know", "check once", "review this", "take a look"
        ]
        return signals.contains(where: { compact.contains($0) })
    }

    private static func looksGroupTaskDumpFollowUp(_ text: String) -> Bool {
        let compact = normalize(text)
        guard !compact.isEmpty else { return false }

        let taskSignals = [
            "need to", "needs to", "changes", "fixes", "todo", "to do",
            "pending", "remaining", "review comments", "figma", "feedback"
        ]
        let ownershipSignals = [
            looksCCStyleMentions(text),
            compact.contains("input"),
            compact.contains("feedback"),
            compact.contains("review")
        ]
        return taskSignals.contains(where: { compact.contains($0) })
            && ownershipSignals.contains(true)
    }

    private static func looksExplanatoryGroupReply(_ text: String) -> Bool {
        let compact = normalize(text)
        guard !compact.isEmpty else { return false }

        let explanatoryStarts = [
            "you mean", "it means", "its too", "it's too", "you can just",
            "you can", "basically", "i think", "this means", "even if you try"
        ]
        return explanatoryStarts.contains(where: { compact.hasPrefix($0) })
    }

    private static func looksCCStyleMentions(_ text: String) -> Bool {
        let compact = normalize(text)
        guard !compact.isEmpty, compact.contains("@") else { return false }
        return compact.range(of: #"\bcc\b\s+(@\w+[\s,]*)+$"#, options: .regularExpression) != nil
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
