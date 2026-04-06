import Foundation

enum ConversationReplyHeuristics {
    static func messageIsFromMe(_ message: TGMessage, myUserId: Int64) -> Bool {
        if case .user(let senderId) = message.senderId {
            return senderId == myUserId
        }
        return false
    }

    static func normalizedSignalText(_ rawText: String?) -> String {
        guard let rawText else { return "" }
        return rawText
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[^a-z0-9\\s?]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func inboundMessageImpliesContactOwnsNextStep(_ compact: String) -> Bool {
        guard !compact.isEmpty else { return false }

        let exactSignals: Set<String> = [
            "on it", "will do", "i will", "i ll", "working on it",
            "let me do it", "let me check", "will share", "will send",
            "done", "completed"
        ]
        if exactSignals.contains(compact) {
            return true
        }

        let phraseSignals = [
            "on it", "will do", "i will", "i ll", "working on",
            "let me", "will share", "will send", "sending", "share soon"
        ]
        return phraseSignals.contains(where: { compact.contains($0) })
    }

    static func inboundMessageLikelyNeedsReply(_ message: TGMessage) -> Bool {
        let compact = normalizedSignalText(message.textContent)
        guard !compact.isEmpty else { return false }

        if compact.contains("?") { return true }

        let requestSignals = [
            "please", "pls", "can you", "could you", "let me know", "update",
            "when", "where", "why", "what", "how", "share", "send",
            "review", "check", "approve", "eta", "follow up", "follow-up", "reply"
        ]
        if requestSignals.contains(where: { compact.contains($0) }) {
            return true
        }

        let acknowledgementSignals: Set<String> = [
            "ok", "okay", "kk", "k", "cool", "great", "done", "noted", "got it",
            "thanks", "thank you", "sure", "hmm", "hmmm", "hmmmm", "haha", "lol",
            "on it", "will do", "dekh rhe", "dekh rahe", "dekh rha", "dekh rahi"
        ]
        if acknowledgementSignals.contains(compact) {
            return false
        }

        let acknowledgementPrefixes = [
            "great", "cool", "nice", "perfect", "awesome", "amazing", "sounds good",
            "got it", "thanks", "thank you", "interacted as well", "done"
        ]
        if acknowledgementPrefixes.contains(where: { compact == $0 || compact.hasPrefix("\($0) ") }) {
            return false
        }

        let wordCount = compact.split(separator: " ").count
        if wordCount <= 3 && compact.count <= 24 {
            return false
        }

        return compact.count >= 28
    }

    static func hasPendingReplySignal(
        chat: TGChat,
        messages: [TGMessage],
        myUserId: Int64
    ) -> Bool {
        let inboundTail = inboundTail(chat: chat, messages: messages, myUserId: myUserId)
        let hasOutbound = messages.contains(where: { messageIsFromMe($0, myUserId: myUserId) })

        guard !inboundTail.isEmpty else { return false }
        if inboundTail.contains(where: inboundMessageLikelyNeedsReply) {
            return true
        }

        if !hasOutbound {
            return chat.unreadCount > 0 && inboundTail.count >= 2
        }

        if chat.unreadCount > 0 && inboundTail.count >= 2 {
            return true
        }

        return false
    }

    static func latestInboundRequiringReply(
        chat: TGChat,
        messages: [TGMessage],
        myUserId: Int64
    ) -> TGMessage? {
        inboundTail(chat: chat, messages: messages, myUserId: myUserId)
            .reversed()
            .first(where: inboundMessageLikelyNeedsReply)
    }

    static func hasStrictReplyOpportunity(
        chat: TGChat,
        messages: [TGMessage],
        myUserId: Int64,
        myUsername: String? = nil
    ) -> Bool {
        let tail = inboundTail(chat: chat, messages: messages, myUserId: myUserId)
        guard !tail.isEmpty else { return false }

        if chat.chatType.isPrivate {
            return latestInboundRequiringReply(chat: chat, messages: messages, myUserId: myUserId) != nil
        }

        guard let latestRelevant = latestInboundRequiringReply(
            chat: chat,
            messages: messages,
            myUserId: myUserId
        ) else {
            return false
        }

        if messageTargetsSomeoneElse(latestRelevant, myUsername: myUsername) {
            return false
        }

        let tailSenders = tail.compactMap(senderIdentity)
        let distinctTailSenders = Set(tailSenders)
        let latestSender = senderIdentity(latestRelevant)

        if distinctTailSenders.count <= 1 {
            return tail.count <= 2
        }

        guard let latestSender else { return false }
        let relevantFromLatestSender = tail.filter {
            senderIdentity($0) == latestSender && inboundMessageLikelyNeedsReply($0)
        }

        return relevantFromLatestSender.count >= 2
    }

    static func hasLikelyDirectedGroupReplyOpportunity(
        chat: TGChat,
        messages: [TGMessage],
        myUserId: Int64,
        myUsername: String? = nil
    ) -> Bool {
        guard chat.chatType.isGroup else { return false }
        if hasStrictReplyOpportunity(
            chat: chat,
            messages: messages,
            myUserId: myUserId,
            myUsername: myUsername
        ) {
            return true
        }

        guard let latestRelevant = latestInboundRequiringReply(
            chat: chat,
            messages: messages,
            myUserId: myUserId
        ) else {
            return false
        }

        if messageTargetsSomeoneElse(latestRelevant, myUsername: myUsername) {
            return false
        }

        let tail = inboundTail(chat: chat, messages: messages, myUserId: myUserId)
        guard let relevantIndex = tail.lastIndex(where: { $0.id == latestRelevant.id }) else {
            return false
        }

        let trailingSlice = Array(tail[relevantIndex...])
        let laterMessages = Array(trailingSlice.dropFirst())
        let distinctTrailingSenders = Set(trailingSlice.compactMap(senderIdentity))
        let memberCount = chat.memberCount ?? 0
        let latestSender = senderIdentity(latestRelevant)

        if chat.unreadCount > 4 {
            return false
        }

        if memberCount > 0 && memberCount > 10 {
            return false
        }

        if let latestSender, laterMessages.contains(where: {
            guard let sender = senderIdentity($0) else { return false }
            return sender != latestSender
        }) {
            return false
        }

        return trailingSlice.count <= 3 && distinctTrailingSenders.count <= 2
    }

    static func resolvePipelineCategory(
        for chat: TGChat,
        hint: String,
        messages: [TGMessage],
        myUserId: Int64
    ) -> String {
        let normalizedHint = hint.lowercased()
        let hasReplySignal = hasPendingReplySignal(
            chat: chat,
            messages: messages,
            myUserId: myUserId
        )
        if hasReplySignal { return "on_me" }

        let latestTextMessage = messages
            .filter { ($0.textContent?.isEmpty == false) }
            .sorted { $0.date > $1.date }
            .first

        guard let latestTextMessage else {
            if normalizedHint == "on_them" || normalizedHint == "quiet" {
                return normalizedHint
            }
            return chat.unreadCount > 0 ? "on_me" : "quiet"
        }

        let latestFromMe = messageIsFromMe(latestTextMessage, myUserId: myUserId)

        if latestFromMe {
            return "on_them"
        }

        if normalizedHint == "on_them" || normalizedHint == "quiet" {
            return normalizedHint
        }

        return "quiet"
    }

    static func isReplyOwed(
        for chat: TGChat,
        messages: [TGMessage],
        myUserId: Int64
    ) -> Bool {
        hasPendingReplySignal(chat: chat, messages: messages, myUserId: myUserId)
    }

    static func normalizePipelineCategory(
        proposed: FollowUpItem.Category,
        suggestedAction: String?,
        chat: TGChat,
        messages: [TGMessage],
        myUserId: Int64
    ) -> FollowUpItem.Category {
        guard myUserId > 0 else { return proposed }

        let textMessages = messages.filter { ($0.textContent?.isEmpty == false) }
        guard !textMessages.isEmpty else { return proposed }

        if hasPendingReplySignal(chat: chat, messages: textMessages, myUserId: myUserId) {
            return .onMe
        }

        let latestText = textMessages.sorted { $0.date > $1.date }.first
        guard let latestText else { return proposed }

        if messageIsFromMe(latestText, myUserId: myUserId) {
            return .onThem
        }

        let compact = normalizedSignalText(latestText.textContent)
        if inboundMessageImpliesContactOwnsNextStep(compact) {
            return .onThem
        }

        if let suggestion = suggestedAction?.lowercased(),
           suggestion.contains("wait for") || suggestion.contains("waiting on") {
            return .onThem
        }

        if proposed == .onThem || proposed == .quiet {
            return proposed
        }

        return .quiet
    }

    private static func inboundTail(
        chat: TGChat,
        messages: [TGMessage],
        myUserId: Int64
    ) -> [TGMessage] {
        let sorted = messages.sorted { $0.date < $1.date }
        guard !sorted.isEmpty else { return [] }

        let lastIndexFromMe = sorted.lastIndex(where: { messageIsFromMe($0, myUserId: myUserId) })
        if let index = lastIndexFromMe {
            return Array(sorted[(index + 1)...].filter { !messageIsFromMe($0, myUserId: myUserId) })
        }

        return sorted.filter { !messageIsFromMe($0, myUserId: myUserId) }
    }

    private static func senderIdentity(_ message: TGMessage) -> String? {
        if let userId = message.senderUserId {
            return "user:\(userId)"
        }
        if let senderName = message.senderName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !senderName.isEmpty {
            return "name:\(senderName.lowercased())"
        }
        return nil
    }

    private static func messageTargetsSomeoneElse(_ message: TGMessage, myUsername: String?) -> Bool {
        let mentions = mentionedUsernames(in: message.textContent)
        guard !mentions.isEmpty else { return false }

        if let myUsername, mentions.contains(myUsername.lowercased()) {
            return false
        }

        return true
    }

    private static func mentionedUsernames(in rawText: String?) -> Set<String> {
        guard let rawText, !rawText.isEmpty else { return [] }
        guard let regex = try? NSRegularExpression(pattern: "@([A-Za-z0-9_]{3,})") else {
            return []
        }

        let nsRange = NSRange(rawText.startIndex..<rawText.endIndex, in: rawText)
        let matches = regex.matches(in: rawText, range: nsRange)

        return Set(matches.compactMap { match in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: rawText) else {
                return nil
            }
            return rawText[range].lowercased()
        })
    }
}
