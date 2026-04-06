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
        let sorted = messages.sorted { $0.date < $1.date }
        guard !sorted.isEmpty else { return chat.unreadCount > 0 }

        let lastIndexFromMe = sorted.lastIndex(where: { messageIsFromMe($0, myUserId: myUserId) })
        let inboundTail: [TGMessage]
        if let index = lastIndexFromMe {
            inboundTail = Array(sorted[(index + 1)...].filter { !messageIsFromMe($0, myUserId: myUserId) })
        } else {
            inboundTail = sorted.filter { !messageIsFromMe($0, myUserId: myUserId) }
        }

        guard !inboundTail.isEmpty else { return false }
        if inboundTail.contains(where: inboundMessageLikelyNeedsReply) {
            return true
        }

        if lastIndexFromMe == nil {
            return chat.unreadCount > 0 && inboundTail.count >= 2
        }

        if chat.unreadCount > 0 && inboundTail.count >= 2 {
            return true
        }

        return false
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
}
