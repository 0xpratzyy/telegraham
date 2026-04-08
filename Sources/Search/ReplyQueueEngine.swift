import Foundation

@MainActor
final class ReplyQueueEngine {
    static let shared = ReplyQueueEngine()

    struct SearchExecution {
        let results: [ReplyQueueResult]
        let debug: AgenticDebugInfo
        let chatAudits: [AgenticDebugChatAudit]
    }

    private struct PendingChat {
        let chat: TGChat
        var messages: [TGMessage]
        let replyOwed: Bool
        let strictReplySignal: Bool
        let effectiveGroupReplySignal: Bool
        let pipelineHint: String
    }

    func search(
        query: String,
        querySpec: QuerySpec,
        aiSearchSourceChats: [TGChat],
        includeBotsInAISearch: Bool,
        telegramService: TelegramService,
        aiService: AIService,
        pipelineHintProvider: @escaping (Int64) async -> String,
        onProgress: ((SearchExecution) -> Void)? = nil
    ) async -> SearchExecution {
        let myUserId = telegramService.currentUser?.id ?? 0
        let myUsername = telegramService.currentUser?.username

        let candidateCollection = collectEligibleChats(
            scope: querySpec.scope,
            replyQueueQuery: true,
            aiSearchSourceChats: aiSearchSourceChats,
            includeBotsInAISearch: includeBotsInAISearch,
            telegramService: telegramService
        )

        var debug = AgenticDebugInfo(
            scopedChats: candidateCollection.included.count,
            maxScanChats: candidateCollection.included.count,
            providerName: aiService.providerType.rawValue,
            providerModel: aiService.providerModel
        )
        for exclusion in candidateCollection.exclusions {
            debug.recordExclusion(exclusion.reason, chatTitle: exclusion.chatTitle)
        }

        var chatAudits: [Int64: AgenticDebugChatAudit] = [:]
        var processedPending: [PendingChat] = []
        var triageByChatId: [Int64: ReplyQueueTriageResultDTO] = [:]
        var needsMore: [PendingChat] = []
        var providerFailed = false
        var providerFailureReason: String?

        for chatBatch in candidateCollection.included.chunked(into: AppConstants.Search.ReplyQueue.aiBatchSize) {
            var batchPending: [PendingChat] = []

            for chat in chatBatch {
                debug.scannedChats += 1
                var audit = AgenticDebugChatAudit(
                    chatId: chat.id,
                    chatTitle: chat.title,
                    chatType: chat.chatType.isPrivate ? "private" : (chat.chatType.isGroup ? "group" : "other")
                )
                audit.scanned = true

                let messages = await initialMessages(for: chat, telegramService: telegramService)
                let filtered = applyTimeRange(messages, timeRange: querySpec.timeRange)
                guard !filtered.isEmpty else {
                    debug.recordExclusion("no messages in active date range", chatTitle: chat.title)
                    audit.prefilterExclusionReason = "no messages in active date range"
                    chatAudits[chat.id] = audit
                    continue
                }

                let pipelineHint = await pipelineHintProvider(chat.id)
                let replyOwed = ConversationReplyHeuristics.isReplyOwed(
                    for: chat,
                    messages: filtered,
                    myUserId: myUserId
                )
                let strictReplySignal = ConversationReplyHeuristics.hasStrictReplyOpportunity(
                    chat: chat,
                    messages: filtered,
                    myUserId: myUserId,
                    myUsername: myUsername
                )
                let effectiveGroupReplySignal = strictReplySignal || ConversationReplyHeuristics.hasLikelyDirectedGroupReplyOpportunity(
                    chat: chat,
                    messages: filtered,
                    myUserId: myUserId,
                    myUsername: myUsername
                )

                debug.inRangeChats += 1
                debug.matchedChats += 1
                if chat.chatType.isPrivate {
                    debug.matchedPrivateChats += 1
                } else if chat.chatType.isGroup {
                    debug.matchedGroupChats += 1
                }
                if replyOwed {
                    debug.replyOwedChats += 1
                }

                audit.inRange = true
                audit.messageCount = filtered.count
                audit.pipelineCategory = (replyOwed || effectiveGroupReplySignal) ? "on_me" : pipelineHint
                audit.replyOwed = replyOwed
                audit.strictReplySignal = strictReplySignal
                audit.effectiveGroupReplySignal = effectiveGroupReplySignal
                chatAudits[chat.id] = audit

                batchPending.append(
                    PendingChat(
                        chat: chat,
                        messages: filtered,
                        replyOwed: replyOwed,
                        strictReplySignal: strictReplySignal,
                        effectiveGroupReplySignal: effectiveGroupReplySignal,
                        pipelineHint: pipelineHint
                    )
                )
            }

            guard !batchPending.isEmpty else {
                publishProgress(
                    processedPending: processedPending,
                    triageByChatId: triageByChatId,
                    debug: debug,
                    chatAudits: chatAudits,
                    myUserId: myUserId,
                    onProgress: onProgress
                )
                continue
            }

            processedPending.append(contentsOf: batchPending)

            let results = await triageBatch(
                query: query,
                scope: querySpec.scope,
                batch: batchPending,
                telegramService: telegramService,
                aiService: aiService,
                myUserId: myUserId
            )

            debug.candidatesSentToAI += batchPending.count
            debug.aiReturned += results.count

            let byId = Dictionary(uniqueKeysWithValues: results.map { ($0.chatId, $0) })
            let missingIds = Set(batchPending.map { $0.chat.id }).subtracting(byId.keys)
            if !missingIds.isEmpty {
                providerFailed = true
                providerFailureReason = "reply queue triage returned a sparse batch"
            }

            for item in batchPending {
                var audit = chatAudits[item.chat.id] ?? AgenticDebugChatAudit(
                    chatId: item.chat.id,
                    chatTitle: item.chat.title,
                    chatType: item.chat.chatType.isPrivate ? "private" : "group"
                )
                audit.sentToAI = true

                guard let triage = byId[item.chat.id] else {
                    let fallback = localFallback(for: item, myUserId: myUserId)
                    triageByChatId[item.chat.id] = fallback
                    audit.aiReason = "local fallback"
                    audit.aiReplyability = fallback.classification
                    audit.aiConfidence = fallback.confidence
                    audit.aiWarmth = fallback.urgency
                    audit.supportingMessageIds = fallback.supportingMessageIds
                    chatAudits[item.chat.id] = audit
                    continue
                }

                audit.aiReason = triage.reason
                audit.aiReplyability = triage.classification
                audit.aiConfidence = triage.confidence
                audit.aiWarmth = triage.urgency
                audit.supportingMessageIds = triage.supportingMessageIds
                chatAudits[item.chat.id] = audit

                if triage.classification == ReplyQueueResult.Classification.needMore.rawValue {
                    needsMore.append(item)
                } else {
                    triageByChatId[item.chat.id] = triage
                }
            }

            publishProgress(
                processedPending: processedPending,
                triageByChatId: triageByChatId,
                debug: debug,
                chatAudits: chatAudits,
                myUserId: myUserId,
                onProgress: onProgress
            )
        }

        guard !processedPending.isEmpty else {
            debug.stopReason = "no eligible chats after coarse filters"
            return SearchExecution(results: [], debug: debug, chatAudits: Array(chatAudits.values))
        }

        if !needsMore.isEmpty {
            let expanded = await expandNeedMore(
                pending: needsMore,
                telegramService: telegramService,
                querySpec: querySpec
            )
            for batch in expanded.chunked(into: AppConstants.Search.ReplyQueue.aiBatchSize) {
                let results = await triageBatch(
                    query: query,
                    scope: querySpec.scope,
                    batch: batch,
                    telegramService: telegramService,
                    aiService: aiService,
                    myUserId: myUserId
                )
                debug.candidatesSentToAI += batch.count
                debug.aiReturned += results.count

                let byId = Dictionary(uniqueKeysWithValues: results.map { ($0.chatId, $0) })
                for item in batch {
                    guard let triage = byId[item.chat.id],
                          triage.classification != ReplyQueueResult.Classification.needMore.rawValue else {
                        triageByChatId[item.chat.id] = localFallback(for: item, myUserId: myUserId)
                        continue
                    }
                    triageByChatId[item.chat.id] = triage
                }

                publishProgress(
                    processedPending: processedPending,
                    triageByChatId: triageByChatId,
                    debug: debug,
                    chatAudits: chatAudits,
                    myUserId: myUserId,
                    onProgress: onProgress
                )
            }
        }

        debug.rankedBeforeValidation = triageByChatId.count

        let finalResults = finalizedResults(
            from: processedPending,
            triageByChatId: triageByChatId,
            myUserId: myUserId,
            chatAudits: &chatAudits
        )
        .prefix(AppConstants.Search.ReplyQueue.maxRenderedResults)
        .map { $0 }

        debug.finalCount = finalResults.count
        debug.finalPrivateChats = finalResults.reduce(into: 0) { count, result in
            if processedPending.first(where: { $0.chat.id == result.chatId })?.chat.chatType.isPrivate == true {
                count += 1
            }
        }
        debug.finalGroupChats = finalResults.reduce(into: 0) { count, result in
            if processedPending.first(where: { $0.chat.id == result.chatId })?.chat.chatType.isGroup == true {
                count += 1
            }
        }
        debug.droppedByValidation = max(0, debug.rankedBeforeValidation - finalResults.count)
        debug.stopReason = providerFailed
            ? "\(providerFailureReason ?? "reply queue provider failure") • using limited local fallback"
            : "triaged all eligible chats"

        return SearchExecution(
            results: finalResults,
            debug: debug,
            chatAudits: sortedChatAudits(chatAudits)
        )
    }

    private func finalizedResults(
        from pending: [PendingChat],
        triageByChatId: [Int64: ReplyQueueTriageResultDTO],
        myUserId: Int64,
        chatAudits: inout [Int64: AgenticDebugChatAudit]
    ) -> [ReplyQueueResult] {
        pending.compactMap { item -> ReplyQueueResult? in
            guard let triage = triageByChatId[item.chat.id] else { return nil }

            guard triage.classification == ReplyQueueResult.Classification.onMe.rawValue else {
                return nil
            }

            if item.chat.chatType.isGroup,
               !item.effectiveGroupReplySignal,
               !item.replyOwed {
                if var audit = chatAudits[item.chat.id] {
                    audit.validationFailureReason = "group not clearly directed at you"
                    chatAudits[item.chat.id] = audit
                }
                return nil
            }

            if var audit = chatAudits[item.chat.id] {
                audit.finalIncluded = true
                chatAudits[item.chat.id] = audit
            }

            return makeReplyQueueResult(
                triage: triage,
                pending: item,
                myUserId: myUserId
            )
        }
        .sorted { lhs, rhs in
            if lhs.latestMessageDate != rhs.latestMessageDate { return lhs.latestMessageDate > rhs.latestMessageDate }
            if lhs.urgency != rhs.urgency { return urgencySortWeight(lhs.urgency) > urgencySortWeight(rhs.urgency) }
            return lhs.confidence > rhs.confidence
        }
    }

    private func provisionalResults(
        from pending: [PendingChat],
        triageByChatId: [Int64: ReplyQueueTriageResultDTO],
        myUserId: Int64
    ) -> [ReplyQueueResult] {
        pending.compactMap { item -> ReplyQueueResult? in
            guard let triage = triageByChatId[item.chat.id],
                  triage.classification == ReplyQueueResult.Classification.onMe.rawValue else {
                return nil
            }

            if item.chat.chatType.isGroup,
               !item.effectiveGroupReplySignal,
               !item.replyOwed {
                return nil
            }

            let result = makeReplyQueueResult(
                triage: triage,
                pending: item,
                myUserId: myUserId
            )
            guard result.confidence >= AppConstants.Search.ReplyQueue.progressiveConfidenceThreshold
                || result.urgency == .high else {
                return nil
            }
            return result
        }
        .sorted { lhs, rhs in
            if lhs.latestMessageDate != rhs.latestMessageDate { return lhs.latestMessageDate > rhs.latestMessageDate }
            if lhs.urgency != rhs.urgency { return urgencySortWeight(lhs.urgency) > urgencySortWeight(rhs.urgency) }
            return lhs.confidence > rhs.confidence
        }
        .prefix(AppConstants.Search.ReplyQueue.maxRenderedResults)
        .map { $0 }
    }

    private func publishProgress(
        processedPending: [PendingChat],
        triageByChatId: [Int64: ReplyQueueTriageResultDTO],
        debug: AgenticDebugInfo,
        chatAudits: [Int64: AgenticDebugChatAudit],
        myUserId: Int64,
        onProgress: ((SearchExecution) -> Void)?
    ) {
        guard let onProgress else { return }

        let provisional = provisionalResults(
            from: processedPending,
            triageByChatId: triageByChatId,
            myUserId: myUserId
        )

        var progressDebug = debug
        progressDebug.rankedBeforeValidation = triageByChatId.count
        progressDebug.finalCount = provisional.count
        progressDebug.finalPrivateChats = provisional.reduce(into: 0) { count, result in
            if processedPending.first(where: { $0.chat.id == result.chatId })?.chat.chatType.isPrivate == true {
                count += 1
            }
        }
        progressDebug.finalGroupChats = provisional.reduce(into: 0) { count, result in
            if processedPending.first(where: { $0.chat.id == result.chatId })?.chat.chatType.isGroup == true {
                count += 1
            }
        }
        progressDebug.droppedByValidation = max(0, progressDebug.rankedBeforeValidation - provisional.count)
        progressDebug.stopReason = provisional.isEmpty
            ? "still triaging eligible chats"
            : "showing \(provisional.count) confident chats so far"

        onProgress(
            SearchExecution(
                results: provisional,
                debug: progressDebug,
                chatAudits: sortedChatAudits(chatAudits)
            )
        )
    }

    private func sortedChatAudits(_ chatAudits: [Int64: AgenticDebugChatAudit]) -> [AgenticDebugChatAudit] {
        Array(chatAudits.values).sorted { lhs, rhs in
            if lhs.finalIncluded != rhs.finalIncluded {
                return lhs.finalIncluded && !rhs.finalIncluded
            }
            return lhs.chatTitle.localizedCaseInsensitiveCompare(rhs.chatTitle) == .orderedAscending
        }
    }

    private func triageBatch(
        query: String,
        scope: QueryScope,
        batch: [PendingChat],
        telegramService: TelegramService,
        aiService: AIService,
        myUserId: Int64
    ) async -> [ReplyQueueTriageResultDTO] {
        let candidates = batch.map { pending in
            ReplyQueueCandidateDTO(
                chatId: pending.chat.id,
                chatName: pending.chat.title,
                chatType: pending.chat.chatType.displayName,
                unreadCount: pending.chat.unreadCount,
                memberCount: pending.chat.memberCount,
                localSignal: localSignal(for: pending),
                messages: snippets(
                    for: pending.messages,
                    chatTitle: pending.chat.title,
                    myUserId: myUserId
                )
            )
        }

        do {
            return try await aiService.provider.triageReplyQueue(
                query: query,
                scope: scope,
                candidates: candidates
            )
        } catch {
            return batch.map { localFallback(for: $0, myUserId: myUserId) }
        }
    }

    private func expandNeedMore(
        pending: [PendingChat],
        telegramService: TelegramService,
        querySpec: QuerySpec
    ) async -> [PendingChat] {
        var expanded: [PendingChat] = []
        expanded.reserveCapacity(pending.count)

        for var item in pending {
            let currentCount = item.messages.count
            let targetCount = min(
                AppConstants.Search.ReplyQueue.maxMessagesPerChat,
                currentCount + AppConstants.Search.ReplyQueue.additionalMessagesForNeedMore
            )

            guard targetCount > currentCount, let oldestId = item.messages.sorted(by: { $0.date < $1.date }).first?.id else {
                expanded.append(item)
                continue
            }

            if let more = try? await telegramService.getChatHistory(
                chatId: item.chat.id,
                fromMessageId: oldestId,
                limit: targetCount - currentCount
            ), !more.isEmpty {
                let merged = Dictionary(
                    uniqueKeysWithValues: (item.messages + more).map { ("\($0.chatId):\($0.id)", $0) }
                )
                item.messages = merged.values.sorted { $0.date > $1.date }
            }

            item.messages = applyTimeRange(item.messages, timeRange: querySpec.timeRange)
            expanded.append(item)
        }

        return expanded
    }

    private func makeReplyQueueResult(
        triage: ReplyQueueTriageResultDTO,
        pending: PendingChat,
        myUserId: Int64
    ) -> ReplyQueueResult {
        let urgency = ReplyQueueResult.Urgency(rawValue: triage.urgency) ?? .medium
        let classification = ReplyQueueResult.Classification(rawValue: triage.classification) ?? .quiet

        var score = urgencyScore(urgency)
        score += Int((max(0, min(1, triage.confidence)) * 12).rounded())
        if pending.chat.chatType.isPrivate { score += 5 }
        if pending.strictReplySignal { score += 6 }
        if pending.effectiveGroupReplySignal { score += 4 }
        if pending.replyOwed { score += 4 }

        let latestMessageDate = pending.messages.map(\.date).max() ?? .distantPast

        if latestMessageDate != .distantPast {
            let age = Date().timeIntervalSince(latestMessageDate)
            if age <= 86_400 { score += 6 }
            else if age <= 3 * 86_400 { score += 3 }
        }

        return ReplyQueueResult(
            chatId: pending.chat.id,
            chatTitle: pending.chat.title,
            suggestedAction: triage.suggestedAction,
            reason: triage.reason,
            confidence: max(0, min(1, triage.confidence)),
            urgency: urgency,
            classification: classification,
            supportingMessageIds: triage.supportingMessageIds,
            latestMessageDate: latestMessageDate,
            score: score,
            source: "ai"
        )
    }

    private func urgencySortWeight(_ urgency: ReplyQueueResult.Urgency) -> Int {
        switch urgency {
        case .high: return 3
        case .medium: return 2
        case .low: return 1
        }
    }

    private func localFallback(
        for pending: PendingChat,
        myUserId: Int64
    ) -> ReplyQueueTriageResultDTO {
        let classification: String
        let urgency: String
        let reason: String

        if pending.chat.chatType.isGroup {
            if pending.effectiveGroupReplySignal || pending.replyOwed {
                classification = ReplyQueueResult.Classification.onMe.rawValue
                urgency = pending.strictReplySignal ? "high" : "medium"
                reason = "Recent group messages still look directed at you."
            } else {
                classification = ReplyQueueResult.Classification.quiet.rawValue
                urgency = "low"
                reason = "No clear on-you group ask in recent context."
            }
        } else if pending.replyOwed || pending.strictReplySignal || pending.pipelineHint == "on_me" {
            classification = ReplyQueueResult.Classification.onMe.rawValue
            urgency = pending.strictReplySignal ? "high" : "medium"
            reason = "Recent DM context still looks like it needs your reply."
        } else if pending.pipelineHint == "on_them" {
            classification = ReplyQueueResult.Classification.onThem.rawValue
            urgency = "low"
            reason = "You likely already replied and are waiting on them."
        } else {
            classification = ReplyQueueResult.Classification.quiet.rawValue
            urgency = "low"
            reason = "No strong reply signal in the current DM window."
        }

        return ReplyQueueTriageResultDTO(
            chatId: pending.chat.id,
            classification: classification,
            urgency: urgency,
            reason: reason,
            suggestedAction: fallbackSuggestedAction(for: pending, myUserId: myUserId),
            confidence: classification == ReplyQueueResult.Classification.onMe.rawValue ? 0.58 : 0.42,
            supportingMessageIds: supportingMessageIds(for: pending, myUserId: myUserId)
        )
    }

    private func collectEligibleChats(
        scope: QueryScope,
        replyQueueQuery: Bool,
        aiSearchSourceChats: [TGChat],
        includeBotsInAISearch: Bool,
        telegramService: TelegramService
    ) -> (included: [TGChat], exclusions: [(reason: String, chatTitle: String)]) {
        let now = Date()
        let maxAge = AppConstants.FollowUp.maxPipelineAgeSeconds

        var included: [TGChat] = []
        var exclusions: [(reason: String, chatTitle: String)] = []

        for chat in aiSearchSourceChats {
            guard let lastMessage = chat.lastMessage else {
                exclusions.append(("no last message", chat.title))
                continue
            }
            guard !chat.chatType.isChannel else {
                exclusions.append(("channel skipped", chat.title))
                continue
            }

            switch scope {
            case .all:
                guard chat.chatType.isPrivate || chat.chatType.isGroup else {
                    exclusions.append(("outside active scope", chat.title))
                    continue
                }
            case .dms:
                guard chat.chatType.isPrivate else {
                    exclusions.append(("outside active scope", chat.title))
                    continue
                }
            case .groups:
                guard chat.chatType.isGroup else {
                    exclusions.append(("outside active scope", chat.title))
                    continue
                }
            }

            let ageLimit = replyQueueQuery && chat.chatType.isPrivate
                ? AppConstants.AI.AgenticSearch.replyQueuePrivateMaxAgeSeconds
                : maxAge
            let age = now.timeIntervalSince(lastMessage.date)
            guard age <= ageLimit else {
                let dayLabel = Int(ageLimit / 86_400)
                exclusions.append(("older than \(dayLabel) days", chat.title))
                continue
            }

            if chat.chatType.isGroup {
                if let count = chat.memberCount, count > AppConstants.FollowUp.maxGroupMembers {
                    exclusions.append(("group too large", chat.title))
                    continue
                }
                if chat.unreadCount > AppConstants.FollowUp.maxGroupUnread {
                    exclusions.append(("group unread too high", chat.title))
                    continue
                }
            }

            if !includeBotsInAISearch && telegramService.isLikelyBotChat(chat) {
                exclusions.append(("bot filtered", chat.title))
                continue
            }

            included.append(chat)
        }

        return (included, exclusions)
    }

    private func initialMessages(
        for chat: TGChat,
        telegramService: TelegramService
    ) async -> [TGMessage] {
        if let cached = await MessageCacheService.shared.getMessages(chatId: chat.id), !cached.isEmpty {
            return Array(cached.prefix(AppConstants.Search.ReplyQueue.initialMessagesPerChat))
        }

        let fetched = (try? await telegramService.getChatHistory(
            chatId: chat.id,
            limit: AppConstants.Search.ReplyQueue.initialMessagesPerChat
        )) ?? []

        if !fetched.isEmpty {
            await MessageCacheService.shared.cacheMessages(chatId: chat.id, messages: fetched)
        }

        return fetched
    }

    private func localSignal(for pending: PendingChat) -> String {
        if pending.effectiveGroupReplySignal {
            return "directed_group_reply"
        }
        if pending.replyOwed || pending.pipelineHint == "on_me" {
            return "on_me"
        }
        if pending.pipelineHint == "on_them" {
            return "on_them"
        }
        return "quiet"
    }

    private func snippets(
        for messages: [TGMessage],
        chatTitle: String,
        myUserId: Int64
    ) -> [MessageSnippet] {
        messages
            .sorted { $0.date < $1.date }
            .compactMap { message in
                guard let text = message.textContent, !text.isEmpty else { return nil }
                let name: String
                if ConversationReplyHeuristics.messageIsFromMe(message, myUserId: myUserId) {
                    name = "[ME]"
                } else {
                    name = message.senderName?.split(separator: " ").first.map(String.init) ?? "Unknown"
                }
                return MessageSnippet(
                    messageId: message.id,
                    senderFirstName: name,
                    text: text,
                    relativeTimestamp: message.relativeDate,
                    chatId: message.chatId,
                    chatName: chatTitle
                )
            }
    }

    private func fallbackSuggestedAction(
        for pending: PendingChat,
        myUserId: Int64
    ) -> String {
        if let latest = ConversationReplyHeuristics.latestInboundRequiringReply(
            chat: pending.chat,
            messages: pending.messages,
            myUserId: myUserId
        ) {
            let sender = latest.senderName?.split(separator: " ").first.map(String.init) ?? "them"
            let snippet = latest.displayText.prefix(80)
            return "Reply to \(sender) about \"\(snippet)\"."
        }

        if pending.chat.chatType.isPrivate {
            return "Check the latest DM and send the next concrete update."
        }
        return "Review the latest group ask and reply only if it is clearly on you."
    }

    private func supportingMessageIds(for pending: PendingChat, myUserId: Int64) -> [Int64] {
        let messages = pending.messages
        if let latest = ConversationReplyHeuristics.latestInboundRequiringReply(
            chat: pending.chat,
            messages: messages,
            myUserId: myUserId
        ) {
            return [latest.id]
        }

        return Array(messages.sorted { $0.date > $1.date }.prefix(2).map(\.id))
    }

    private func urgencyScore(_ urgency: ReplyQueueResult.Urgency) -> Int {
        switch urgency {
        case .high: return 84
        case .medium: return 70
        case .low: return 56
        }
    }

    private func applyTimeRange(_ messages: [TGMessage], timeRange: TimeRangeConstraint?) -> [TGMessage] {
        guard let timeRange else { return messages }
        return messages.filter { timeRange.contains($0.date) }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        var chunks: [[Element]] = []
        chunks.reserveCapacity((count / size) + 1)

        var index = startIndex
        while index < endIndex {
            let nextIndex = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            chunks.append(Array(self[index..<nextIndex]))
            index = nextIndex
        }

        return chunks
    }
}
