import Foundation

enum FollowUpPipelineAnalyzer {
    static func collectCandidateChats(
        from chats: [TGChat],
        includeBots: Bool,
        isLikelyBot: (TGChat) -> Bool
    ) -> [TGChat] {
        let base = SearchChatEligibilityFilter.collectCandidateChats(
            from: chats,
            scope: .all,
            replyQueueQuery: false
        )

        return SearchChatEligibilityFilter.applyingLikelyBotFilter(
            to: base,
            includeBots: includeBots,
            isLikelyBot: isLikelyBot
        ).included
    }

    static func buildRuleBasedFallbackItems(
        from candidates: [TGChat],
        myUserId: Int64?
    ) -> [FollowUpItem] {
        guard let myUserId else { return [] }
        let now = Date()

        return candidates.compactMap { chat -> FollowUpItem? in
            guard let lastMessage = chat.lastMessage else { return nil }
            let age = now.timeIntervalSince(lastMessage.date)
            let isFromMe = ConversationReplyHeuristics.messageIsFromMe(lastMessage, myUserId: myUserId)

            if !isFromMe && chat.unreadCount > 0 {
                return FollowUpItem(
                    chat: chat,
                    category: .onMe,
                    lastMessage: lastMessage,
                    timeSinceLastActivity: age,
                    suggestedAction: fallbackSuggestedAction(
                        for: .onMe,
                        existing: nil,
                        age: age
                    )
                )
            }

            if isFromMe && age > AppConstants.FollowUp.followUpThresholdSeconds {
                return FollowUpItem(
                    chat: chat,
                    category: .onThem,
                    lastMessage: lastMessage,
                    timeSinceLastActivity: age,
                    suggestedAction: fallbackSuggestedAction(
                        for: .onThem,
                        existing: nil,
                        age: age
                    )
                )
            }

            if age > AppConstants.FollowUp.staleThresholdSeconds {
                return FollowUpItem(
                    chat: chat,
                    category: .quiet,
                    lastMessage: lastMessage,
                    timeSinceLastActivity: age,
                    suggestedAction: fallbackSuggestedAction(
                        for: .quiet,
                        existing: nil,
                        age: age
                    )
                )
            }

            return nil
        }
        .sorted { lhs, rhs in
            if abs(lhs.timeSinceLastActivity - rhs.timeSinceLastActivity) > 3600 {
                return lhs.timeSinceLastActivity < rhs.timeSinceLastActivity
            }
            let order: [FollowUpItem.Category] = [.onMe, .onThem, .quiet]
            return (order.firstIndex(of: lhs.category) ?? 2) < (order.firstIndex(of: rhs.category) ?? 2)
        }
    }

    static func categorizeChat(
        chat: TGChat,
        myUserId: Int64,
        telegramService: TelegramService,
        aiService: AIService
    ) async -> FollowUpItem? {
        guard let lastMessage = chat.lastMessage else { return nil }
        let age = Date().timeIntervalSince(lastMessage.date)
        let initialWindowSize = AppConstants.FollowUp.messagesPerChat
        let progressiveStep = AppConstants.FollowUp.progressiveFetchStep
        let maxMessages = AppConstants.FollowUp.maxMessagesForAIClassification
        let maxAIAttempts = 2
        let defaultNeedMoreMessages = 20
        let cache = MessageCacheService.shared
        let currentUser = await telegramService.currentUser
        let resolvedMemberCount = await telegramService.resolvedMemberCount(for: chat)
        let effectiveChat = chat.updating(memberCount: resolvedMemberCount ?? chat.memberCount)

        var allMessages: [TGMessage] = []

        if let cached = await cache.getMessages(chatId: chat.id) {
            allMessages = cached
        }

        if allMessages.count < initialWindowSize {
            do {
                let fetched = try await telegramService.getChatHistory(
                    chatId: chat.id,
                    limit: initialWindowSize
                )
                allMessages = fetched
                await cache.cacheMessages(chatId: chat.id, messages: fetched)
            } catch {
                if allMessages.isEmpty { return nil }
            }
        }

        allMessages.sort { $0.date > $1.date }

        var currentWindowSize = min(initialWindowSize, min(allMessages.count, maxMessages))
        guard currentWindowSize > 0 else { return nil }

        let classificationStrategy = classificationStrategy(for: effectiveChat)

        func expandWindow(toAtLeast targetSize: Int) async -> Bool {
            let target = min(maxMessages, targetSize)
            guard target > currentWindowSize else { return false }

            while allMessages.count < target {
                let remaining = target - allMessages.count
                let fetchLimit = min(max(progressiveStep, 1), remaining)
                guard fetchLimit > 0 else { break }

                let oldestId = allMessages.last?.id ?? 0
                guard oldestId != 0 else { break }

                do {
                    let moreMessages = try await telegramService.getChatHistory(
                        chatId: chat.id,
                        fromMessageId: oldestId,
                        limit: fetchLimit
                    )
                    guard !moreMessages.isEmpty else { break }
                    allMessages.append(contentsOf: moreMessages)
                    allMessages.sort { $0.date > $1.date }
                    await cache.cacheMessages(chatId: chat.id, messages: moreMessages, append: true)
                } catch {
                    break
                }
            }

            let updatedWindowSize = min(target, allMessages.count)
            guard updatedWindowSize > currentWindowSize else { return false }
            currentWindowSize = updatedWindowSize
            return true
        }

        if classificationStrategy == .localDirectedSignalsOnly {
            let localWindow = Array(allMessages.prefix(currentWindowSize))
            let localCategory = localOnlyCategory(
                for: effectiveChat,
                messages: localWindow,
                myUserId: myUserId,
                myUsername: currentUser?.username
            )
            let localSuggestion = fallbackSuggestedAction(
                for: localCategory,
                existing: nil,
                age: age
            )

            await cache.cachePipelineCategory(
                chatId: effectiveChat.id,
                category: pipelineCategoryString(localCategory),
                suggestedAction: localSuggestion ?? "",
                lastMessageId: lastMessage.id
            )

            return FollowUpItem(
                chat: effectiveChat,
                category: localCategory,
                lastMessage: lastMessage,
                timeSinceLastActivity: age,
                suggestedAction: localSuggestion
            )
        }

        var attempt = 0
        while attempt < maxAIAttempts {
            attempt += 1
            let messagesToSend = Array(allMessages.prefix(currentWindowSize))

            do {
                let triage = try await aiService.categorizePipelineChat(
                    chat: effectiveChat,
                    messages: messagesToSend,
                    myUserId: myUserId,
                    myUser: currentUser
                )

                switch triage.status {
                case .needMore:
                    guard attempt == 1 else { break }
                    let requested = triage.additionalMessages ?? defaultNeedMoreMessages
                    let boundedAdditional = max(10, min(defaultNeedMoreMessages, requested))
                    let targetWindowSize = min(maxMessages, currentWindowSize + boundedAdditional)
                    guard await expandWindow(toAtLeast: targetWindowSize) else { break }
                    continue

                case .decision:
                    let finalSuggestion = fallbackSuggestedAction(
                        for: triage.category,
                        existing: triage.suggestedAction,
                        age: age
                    )

                    let needsConfidenceRetry = !triage.confident
                        && attempt == 1
                        && currentWindowSize < maxMessages
                    if needsConfidenceRetry {
                        let targetWindowSize = min(maxMessages, currentWindowSize + defaultNeedMoreMessages)
                        guard await expandWindow(toAtLeast: targetWindowSize) else { break }
                        continue
                    }

                    await cache.cachePipelineCategory(
                        chatId: effectiveChat.id,
                        category: pipelineCategoryString(triage.category),
                        suggestedAction: finalSuggestion ?? "",
                        lastMessageId: lastMessage.id
                    )

                    return FollowUpItem(
                        chat: effectiveChat,
                        category: triage.category,
                        lastMessage: lastMessage,
                        timeSinceLastActivity: age,
                        suggestedAction: finalSuggestion
                    )
                }
            } catch {
                break
            }
        }

        let fallbackWindow = Array(allMessages.prefix(currentWindowSize))
        let fallbackCategoryHint = ConversationReplyHeuristics.resolvePipelineCategory(
            for: effectiveChat,
            hint: "quiet",
            messages: fallbackWindow,
            myUserId: myUserId
        )

        let fallbackCategory: FollowUpItem.Category
        switch fallbackCategoryHint {
        case "on_me":
            fallbackCategory = .onMe
        case "on_them":
            fallbackCategory = .onThem
        default:
            fallbackCategory = .quiet
        }

        let fallbackSuggestion = fallbackSuggestedAction(
            for: fallbackCategory,
            existing: nil,
            age: age
        )

        await cache.cachePipelineCategory(
            chatId: effectiveChat.id,
            category: pipelineCategoryString(fallbackCategory),
            suggestedAction: fallbackSuggestion ?? "",
            lastMessageId: lastMessage.id
        )

        return FollowUpItem(
            chat: effectiveChat,
            category: fallbackCategory,
            lastMessage: lastMessage,
            timeSinceLastActivity: age,
            suggestedAction: fallbackSuggestion
        )
    }

    static func fallbackSuggestedAction(
        for category: FollowUpItem.Category,
        existing: String?,
        age: TimeInterval
    ) -> String? {
        let trimmed = existing?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lowered = trimmed.lowercased()

        switch category {
        case .quiet:
            return nil
        case .onMe:
            if !trimmed.isEmpty,
               trimmed.caseInsensitiveCompare("No action needed") != .orderedSame,
               !suggestionImpliesWaiting(lowered) {
                return trimmed
            }
        case .onThem:
            if !trimmed.isEmpty,
               trimmed.caseInsensitiveCompare("No action needed") != .orderedSame,
               !suggestionImpliesReply(lowered) {
                return trimmed
            }
        }

        switch category {
        case .onMe:
            return "Reply with a concrete next step."
        case .onThem:
            return age > 24 * 3600
                ? "Send a short nudge for an update."
                : "Wait for their next message."
        case .quiet:
            return nil
        }
    }

    private static func suggestionImpliesReply(_ suggestion: String) -> Bool {
        let replySignals = [
            "reply", "respond", "answer", "send the reply", "get back to"
        ]
        return replySignals.contains(where: { suggestion.contains($0) })
    }

    private static func suggestionImpliesWaiting(_ suggestion: String) -> Bool {
        let waitSignals = [
            "wait for", "waiting on", "nudge", "follow up later", "follow-up later"
        ]
        return waitSignals.contains(where: { suggestion.contains($0) })
    }

    private enum ClassificationStrategy {
        case ai
        case localDirectedSignalsOnly
    }

    private static func classificationStrategy(for chat: TGChat) -> ClassificationStrategy {
        if chat.chatType.isPrivate {
            return .ai
        }

        if chat.chatType.isGroup,
           let memberCount = chat.memberCount,
           memberCount <= AppConstants.FollowUp.maxGroupMembers {
            return .ai
        }

        return .localDirectedSignalsOnly
    }

    private static func localOnlyCategory(
        for chat: TGChat,
        messages: [TGMessage],
        myUserId: Int64,
        myUsername: String?
    ) -> FollowUpItem.Category {
        guard chat.chatType.isGroup else { return .quiet }

        let strictReplySignal = ConversationReplyHeuristics.hasStrictReplyOpportunity(
            chat: chat,
            messages: messages,
            myUserId: myUserId,
            myUsername: myUsername
        )
        let effectiveGroupReplySignal = strictReplySignal || ConversationReplyHeuristics.hasLikelyDirectedGroupReplyOpportunity(
            chat: chat,
            messages: messages,
            myUserId: myUserId,
            myUsername: myUsername
        )

        return effectiveGroupReplySignal ? .onMe : .quiet
    }

    static func pipelineCategoryString(_ category: FollowUpItem.Category) -> String {
        switch category {
        case .onMe: return "on_me"
        case .onThem: return "on_them"
        case .quiet: return "quiet"
        }
    }
}
