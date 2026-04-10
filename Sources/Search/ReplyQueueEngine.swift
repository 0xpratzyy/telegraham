import Foundation

@MainActor
final class ReplyQueueEngine {
    static let shared = ReplyQueueEngine()

    private struct PersistedReplyQueueCandidate: Codable {
        let order: Int
        let chatId: Int64
        let chatName: String
        let chatType: String
        let unreadCount: Int
        let memberCount: Int?
        let localSignal: String
        let pipelineHint: String
        let replyOwed: Bool
        let strictReplySignal: Bool
        let effectiveGroupReplySignal: Bool
        let messages: [MessageSnippet]
    }

    private struct PersistedReplyQueueCandidateSnapshot: Codable {
        let query: String
        let scope: QueryScope
        let providerName: String
        let providerModel: String
        let capturedAt: Date
        let candidates: [PersistedReplyQueueCandidate]
    }

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

    private struct TriageBatchOutcome: Sendable {
        let results: [ReplyQueueTriageResultDTO]
        let usedLocalFallback: Bool
        let failureReason: String?
    }

    private struct ParallelAIBatchOutcome: Sendable {
        let label: String
        let candidateChatIds: [Int64]
        let candidateCount: Int
        let durationMs: Int
        let outcome: TriageBatchOutcome
    }

    private struct InitialBatchLoad: Sendable {
        let chatId: Int64
        let messages: [TGMessage]
        let source: MessageCacheService.MessageLoadSource
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
        let totalStartedAt = Date()
        let myUserId = telegramService.currentUser?.id ?? 0
        let myUsername = telegramService.currentUser?.username
        let replyQueueConfig = aiService.replyQueueExecutionConfig()

        let collectStartedAt = Date()
        let candidateCollection = collectEligibleChats(
            scope: querySpec.scope,
            replyQueueQuery: true,
            aiSearchSourceChats: aiSearchSourceChats,
            includeBotsInAISearch: includeBotsInAISearch,
            telegramService: telegramService
        )
        let collectDurationMs = elapsedMs(since: collectStartedAt)

        var debug = AgenticDebugInfo(
            scopedChats: candidateCollection.included.count,
            maxScanChats: candidateCollection.included.count,
            providerName: replyQueueConfig?.providerType.rawValue ?? aiService.providerType.rawValue,
            providerModel: replyQueueConfig?.model ?? aiService.providerModel
        )
        debug.candidateCollectionMs = collectDurationMs
        debug.eligiblePrivateChats = candidateCollection.included.filter { $0.chatType.isPrivate }.count
        debug.eligibleGroupChats = candidateCollection.included.filter { $0.chatType.isGroup }.count
        for exclusion in candidateCollection.exclusions {
            debug.recordExclusion(exclusion.reason, chatTitle: exclusion.chatTitle)
        }

        var chatAudits: [Int64: AgenticDebugChatAudit] = [:]
        let prioritizeStartedAt = Date()
        let prioritizedChats = prioritizeEligibleChats(candidateCollection.included)
        debug.prioritizationMs = elapsedMs(since: prioritizeStartedAt)
        let cappedChats = Array(prioritizedChats.prefix(AppConstants.Search.ReplyQueue.maxScannedChats))
        debug.maxScanChats = cappedChats.count
        debug.cappedPrivateChats = cappedChats.filter { $0.chatType.isPrivate }.count
        debug.cappedGroupChats = cappedChats.filter { $0.chatType.isGroup }.count

        var processedPending: [PendingChat] = []
        var triageByChatId: [Int64: ReplyQueueTriageResultDTO] = [:]
        var triageSourceByChatId: [Int64: String] = [:]
        var needsMore: [PendingChat] = []
        var providerFailed = false
        var providerFailureReason: String?
        var previousProvisionalCount = 0
        var didEarlyStop = false

        for (waveIndex, chatWave) in cappedChats.chunked(into: AppConstants.Search.ReplyQueue.scanWaveSize).enumerated() {
            var waveLocalPrepMs = 0
            var waveAIMs = 0
            let batchPrepStartedAt = Date()
            let initialMessagesByChatId = await loadInitialMessagesLocally(for: chatWave)
            let batchPrepLoadMs = elapsedMs(since: batchPrepStartedAt)
            waveLocalPrepMs += batchPrepLoadMs
            debug.localPrepMs += batchPrepLoadMs
            for load in initialMessagesByChatId.values {
                switch load.source {
                case .memory:
                    debug.memoryHitChats += 1
                case .sqlite:
                    debug.sqliteHitChats += 1
                case .empty:
                    debug.emptyLocalChats += 1
                }
            }

            var wavePending: [PendingChat] = []
            let batchHeuristicsStartedAt = Date()
            for chat in chatWave {
                debug.scannedChats += 1
                var audit = AgenticDebugChatAudit(
                    chatId: chat.id,
                    chatTitle: chat.title,
                    chatType: chat.chatType.isPrivate ? "private" : (chat.chatType.isGroup ? "group" : "other")
                )
                audit.scanned = true

                let messages = initialMessagesByChatId[chat.id]?.messages ?? []
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

                wavePending.append(
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
            let heuristicsDurationMs = elapsedMs(since: batchHeuristicsStartedAt)
            waveLocalPrepMs += heuristicsDurationMs
            debug.localPrepMs += heuristicsDurationMs

            guard !wavePending.isEmpty else {
                publishProgress(
                    processedPending: processedPending,
                    triageByChatId: triageByChatId,
                    triageSourceByChatId: triageSourceByChatId,
                    debug: debug,
                    providerFailed: providerFailed,
                    chatAudits: chatAudits,
                    myUserId: myUserId,
                    onProgress: onProgress
                )
                continue
            }

            processedPending.append(contentsOf: wavePending)
            let pendingByChatId = Dictionary(uniqueKeysWithValues: wavePending.map { ($0.chat.id, $0) })
            let outcomes = await runParallelAIBatches(
                labelPrefix: "wave\(waveIndex + 1)-batch",
                query: query,
                scope: querySpec.scope,
                batches: wavePending.chunked(into: AppConstants.Search.ReplyQueue.aiBatchSize),
                providerConfig: replyQueueConfig,
                myUserId: myUserId
            )

            for completed in outcomes {
                waveAIMs += completed.durationMs
                debug.aiMs += completed.durationMs
                debug.aiBatchCount += 1
                debug.batchTimings.append(
                    AgenticDebugBatchTiming(
                        label: completed.label,
                        size: completed.candidateCount,
                        durationMs: completed.durationMs,
                        resultCount: completed.outcome.results.count
                    )
                )
                debug.candidatesSentToAI += completed.candidateCount
                debug.aiReturned += completed.outcome.results.count

                if completed.outcome.usedLocalFallback {
                    providerFailed = true
                    providerFailureReason = completed.outcome.failureReason ?? "reply queue triage failed"
                }

                let byId = Dictionary(uniqueKeysWithValues: completed.outcome.results.map { ($0.chatId, $0) })
                let missingIds = Set(completed.candidateChatIds).subtracting(byId.keys)
                if !missingIds.isEmpty {
                    providerFailed = true
                    providerFailureReason = "reply queue triage returned a sparse batch"
                }

                for chatId in completed.candidateChatIds {
                    guard let item = pendingByChatId[chatId] else { continue }
                    var audit = chatAudits[item.chat.id] ?? AgenticDebugChatAudit(
                        chatId: item.chat.id,
                        chatTitle: item.chat.title,
                        chatType: item.chat.chatType.isPrivate ? "private" : "group"
                    )
                    audit.sentToAI = true

                    guard let triage = byId[item.chat.id] else {
                        let fallback = localFallback(for: item, myUserId: myUserId)
                        triageByChatId[item.chat.id] = fallback
                        triageSourceByChatId[item.chat.id] = "local_fallback"
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
                        triageSourceByChatId[item.chat.id] = completed.outcome.usedLocalFallback ? "local_fallback" : "ai"
                    }
                }

                publishProgress(
                    processedPending: processedPending,
                    triageByChatId: triageByChatId,
                    triageSourceByChatId: triageSourceByChatId,
                    debug: debug,
                    providerFailed: providerFailed,
                    chatAudits: chatAudits,
                    myUserId: myUserId,
                    onProgress: onProgress
                )
            }

            let provisional = provisionalResults(
                from: processedPending,
                triageByChatId: triageByChatId,
                triageSourceByChatId: triageSourceByChatId,
                myUserId: myUserId,
                providerFailed: providerFailed
            )
            debug.waveTimings.append(
                AgenticDebugWaveTiming(
                    wave: waveIndex + 1,
                    chatCount: chatWave.count,
                    localPrepMs: waveLocalPrepMs,
                    aiMs: waveAIMs,
                    provisionalCount: provisional.count
                )
            )

            if !providerFailed,
               waveIndex + 1 >= AppConstants.Search.ReplyQueue.minimumWaveCountBeforeEarlyStop,
               provisional.count >= AppConstants.Search.ReplyQueue.minimumConfidentResultsForEarlyStop {
                let growth = provisional.count - previousProvisionalCount
                let freshCount = freshResultCount(in: provisional)
                if growth <= AppConstants.Search.ReplyQueue.stableGrowthThreshold,
                   freshCount >= min(
                    provisional.count,
                    AppConstants.Search.ReplyQueue.minimumConfidentResultsForEarlyStop
                   ) {
                    debug.stopReason = "early stop after stable confident results at \(debug.scannedChats) scans"
                    didEarlyStop = true
                    break
                }
            }

            previousProvisionalCount = provisional.count
        }

        guard !processedPending.isEmpty else {
            debug.stopReason = "no eligible chats after coarse filters"
            debug.totalDurationMs = elapsedMs(since: totalStartedAt)
            return SearchExecution(results: [], debug: debug, chatAudits: Array(chatAudits.values))
        }

        if !needsMore.isEmpty {
            debug.needMoreCount = needsMore.count
            let needMoreStartedAt = Date()
            let expanded = await expandNeedMore(
                pending: needsMore,
                querySpec: querySpec
            )
            debug.needMoreMs += elapsedMs(since: needMoreStartedAt)
            let expandedByChatId = Dictionary(uniqueKeysWithValues: expanded.map { ($0.chat.id, $0) })
            let outcomes = await runParallelAIBatches(
                labelPrefix: "need-more-batch",
                query: query,
                scope: querySpec.scope,
                batches: expanded.chunked(into: AppConstants.Search.ReplyQueue.aiBatchSize),
                providerConfig: replyQueueConfig,
                myUserId: myUserId
            )
            for completed in outcomes {
                debug.aiMs += completed.durationMs
                debug.aiBatchCount += 1
                debug.batchTimings.append(
                    AgenticDebugBatchTiming(
                        label: completed.label,
                        size: completed.candidateCount,
                        durationMs: completed.durationMs,
                        resultCount: completed.outcome.results.count
                    )
                )
                debug.candidatesSentToAI += completed.candidateCount
                debug.aiReturned += completed.outcome.results.count
                if completed.outcome.usedLocalFallback {
                    providerFailed = true
                    providerFailureReason = completed.outcome.failureReason ?? "reply queue triage failed"
                }

                let byId = Dictionary(uniqueKeysWithValues: completed.outcome.results.map { ($0.chatId, $0) })
                let missingIds = Set(completed.candidateChatIds).subtracting(byId.keys)
                if !missingIds.isEmpty {
                    providerFailed = true
                    providerFailureReason = "reply queue triage returned a sparse need-more batch"
                }
                for chatId in completed.candidateChatIds {
                    guard let item = expandedByChatId[chatId] else { continue }
                    guard let triage = byId[item.chat.id],
                          triage.classification != ReplyQueueResult.Classification.needMore.rawValue else {
                        triageByChatId[item.chat.id] = localFallback(for: item, myUserId: myUserId)
                        triageSourceByChatId[item.chat.id] = "local_fallback"
                        continue
                    }
                    triageByChatId[item.chat.id] = triage
                    triageSourceByChatId[item.chat.id] = completed.outcome.usedLocalFallback ? "local_fallback" : "ai"
                }

                publishProgress(
                    processedPending: processedPending,
                    triageByChatId: triageByChatId,
                    triageSourceByChatId: triageSourceByChatId,
                    debug: debug,
                    providerFailed: providerFailed,
                    chatAudits: chatAudits,
                    myUserId: myUserId,
                    onProgress: onProgress
                )
            }
        }

        debug.rankedBeforeValidation = triageByChatId.count

        let finalizeStartedAt = Date()
        let finalResults = finalizedResults(
            from: processedPending,
            triageByChatId: triageByChatId,
            triageSourceByChatId: triageSourceByChatId,
            myUserId: myUserId,
            providerFailed: providerFailed,
            chatAudits: &chatAudits
        )
        .prefix(AppConstants.Search.ReplyQueue.maxRenderedResults)
        .map { $0 }
        debug.finalizationMs = elapsedMs(since: finalizeStartedAt)

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
        if providerFailed {
            debug.stopReason = "\(providerFailureReason ?? "reply queue provider failure") • using limited local fallback"
        } else if !didEarlyStop {
            debug.stopReason = "triaged capped chat set"
        }
        debug.totalDurationMs = elapsedMs(since: totalStartedAt)
        persistCandidateSnapshot(
            query: query,
            scope: querySpec.scope,
            providerName: replyQueueConfig?.providerType.rawValue ?? aiService.providerType.rawValue,
            providerModel: replyQueueConfig?.model ?? aiService.providerModel,
            pending: processedPending,
            myUserId: myUserId
        )

        return SearchExecution(
            results: finalResults,
            debug: debug,
            chatAudits: sortedChatAudits(chatAudits)
        )
    }

    private func finalizedResults(
        from pending: [PendingChat],
        triageByChatId: [Int64: ReplyQueueTriageResultDTO],
        triageSourceByChatId: [Int64: String],
        myUserId: Int64,
        providerFailed: Bool,
        chatAudits: inout [Int64: AgenticDebugChatAudit]
    ) -> [ReplyQueueResult] {
        let results = pending.compactMap { item -> ReplyQueueResult? in
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
                myUserId: myUserId,
                source: triageSourceByChatId[item.chat.id] ?? "ai"
            )
        }
        return limitFallbackResults(
            pruneStaleResultsIfNeeded(sortReplyQueueResults(results)),
            providerFailed: providerFailed
        )
    }

    private func provisionalResults(
        from pending: [PendingChat],
        triageByChatId: [Int64: ReplyQueueTriageResultDTO],
        triageSourceByChatId: [Int64: String],
        myUserId: Int64,
        providerFailed: Bool
    ) -> [ReplyQueueResult] {
        let results = pending.compactMap { item -> ReplyQueueResult? in
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
                myUserId: myUserId,
                source: triageSourceByChatId[item.chat.id] ?? "ai"
            )
            guard result.confidence >= AppConstants.Search.ReplyQueue.progressiveConfidenceThreshold
                || result.urgency == .high else {
                return nil
            }
            return result
        }
        return Array(
            limitFallbackResults(
                pruneStaleResultsIfNeeded(sortReplyQueueResults(results)),
                providerFailed: providerFailed
            )
            .prefix(AppConstants.Search.ReplyQueue.maxRenderedResults)
        )
    }

    private func publishProgress(
        processedPending: [PendingChat],
        triageByChatId: [Int64: ReplyQueueTriageResultDTO],
        triageSourceByChatId: [Int64: String],
        debug: AgenticDebugInfo,
        providerFailed: Bool,
        chatAudits: [Int64: AgenticDebugChatAudit],
        myUserId: Int64,
        onProgress: ((SearchExecution) -> Void)?
    ) {
        guard let onProgress else { return }

        let provisional = provisionalResults(
            from: processedPending,
            triageByChatId: triageByChatId,
            triageSourceByChatId: triageSourceByChatId,
            myUserId: myUserId,
            providerFailed: providerFailed
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
            ? (providerFailed ? "AI triage unavailable • using limited local fallback" : "still triaging eligible chats")
            : (providerFailed
                ? "showing \(provisional.count) likely chats • using limited local fallback"
                : "showing \(provisional.count) confident chats so far")

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

    private func candidateDTO(
        for pending: PendingChat,
        myUserId: Int64
    ) -> ReplyQueueCandidateDTO {
        ReplyQueueCandidateDTO(
            chatId: pending.chat.id,
            chatName: pending.chat.title,
            chatType: pending.chat.chatType.displayName,
            unreadCount: pending.chat.unreadCount,
            memberCount: pending.chat.memberCount,
            localSignal: localSignal(for: pending),
            pipelineHint: pending.pipelineHint,
            replyOwed: pending.replyOwed,
            strictReplySignal: pending.strictReplySignal,
            effectiveGroupReplySignal: pending.effectiveGroupReplySignal,
            messages: snippets(
                for: pending.messages,
                chatTitle: pending.chat.title,
                myUserId: myUserId
            )
        )
    }

    private func runParallelAIBatches(
        labelPrefix: String,
        query: String,
        scope: QueryScope,
        batches: [[PendingChat]],
        providerConfig: AIService.ReplyQueueExecutionConfig?,
        myUserId: Int64
    ) async -> [ParallelAIBatchOutcome] {
        await withTaskGroup(of: ParallelAIBatchOutcome.self) { group in
            for (index, batch) in batches.enumerated() {
                let candidates = batch.map { candidateDTO(for: $0, myUserId: myUserId) }
                let batchChatIds = batch.map(\.chat.id)
                let label = "\(labelPrefix)\(index + 1)"
                group.addTask {
                    let startedAt = Date()
                    let outcome = await Self.triageCandidates(
                        query: query,
                        scope: scope,
                        candidates: candidates,
                        providerConfig: providerConfig
                    )
                    let durationMs = Int((Date().timeIntervalSince(startedAt) * 1000).rounded())
                    return ParallelAIBatchOutcome(
                        label: label,
                        candidateChatIds: batchChatIds,
                        candidateCount: candidates.count,
                        durationMs: durationMs,
                        outcome: outcome
                    )
                }
            }

            var outcomes: [ParallelAIBatchOutcome] = []
            for await outcome in group {
                outcomes.append(outcome)
            }
            return outcomes
        }
    }

    nonisolated private static func triageCandidates(
        query: String,
        scope: QueryScope,
        candidates: [ReplyQueueCandidateDTO],
        providerConfig: AIService.ReplyQueueExecutionConfig?
    ) async -> TriageBatchOutcome {
        guard let providerConfig else {
            return TriageBatchOutcome(
                results: [],
                usedLocalFallback: true,
                failureReason: "AI provider not configured"
            )
        }

        let provider: AIProvider
        switch providerConfig.providerType {
        case .openai:
            provider = OpenAIProvider(apiKey: providerConfig.apiKey, model: providerConfig.model)
        case .claude:
            provider = ClaudeProvider(apiKey: providerConfig.apiKey, model: providerConfig.model)
        case .none:
            return TriageBatchOutcome(
                results: [],
                usedLocalFallback: true,
                failureReason: "AI provider not configured"
            )
        }

        do {
            return TriageBatchOutcome(
                results: try await provider.triageReplyQueue(
                    query: query,
                    scope: scope,
                    candidates: candidates
                ),
                usedLocalFallback: false,
                failureReason: nil
            )
        } catch {
            return TriageBatchOutcome(
                results: [],
                usedLocalFallback: true,
                failureReason: "AI triage failed: \(error.localizedDescription)"
            )
        }
    }

    private func expandNeedMore(
        pending: [PendingChat],
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

            guard targetCount > currentCount else {
                expanded.append(item)
                continue
            }

            let expandedLocal = await Self.loadLocalMessages(for: item.chat, limit: targetCount)
            if !expandedLocal.messages.isEmpty {
                item.messages = expandedLocal.messages
            }

            item.messages = applyTimeRange(item.messages, timeRange: querySpec.timeRange)
            expanded.append(item)
        }

        return expanded
    }

    private func makeReplyQueueResult(
        triage: ReplyQueueTriageResultDTO,
        pending: PendingChat,
        myUserId: Int64,
        source: String
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
            source: source
        )
    }

    private func urgencySortWeight(_ urgency: ReplyQueueResult.Urgency) -> Int {
        switch urgency {
        case .high: return 3
        case .medium: return 2
        case .low: return 1
        }
    }

    private func sortReplyQueueResults(_ results: [ReplyQueueResult]) -> [ReplyQueueResult] {
        results.sorted { lhs, rhs in
            if lhs.latestMessageDate != rhs.latestMessageDate { return lhs.latestMessageDate > rhs.latestMessageDate }
            if lhs.urgency != rhs.urgency { return urgencySortWeight(lhs.urgency) > urgencySortWeight(rhs.urgency) }
            return lhs.confidence > rhs.confidence
        }
    }

    private func freshResultCount(in results: [ReplyQueueResult]) -> Int {
        let cutoff = Date().addingTimeInterval(-AppConstants.Search.ReplyQueue.preferredFreshResultAgeSeconds)
        return results.filter { $0.latestMessageDate >= cutoff }.count
    }

    private func pruneStaleResultsIfNeeded(_ results: [ReplyQueueResult]) -> [ReplyQueueResult] {
        let cutoff = Date().addingTimeInterval(-AppConstants.Search.ReplyQueue.preferredFreshResultAgeSeconds)
        let freshResults = results.filter { $0.latestMessageDate >= cutoff }
        guard freshResults.count >= AppConstants.Search.ReplyQueue.minimumFreshResultsBeforeDroppingStale else {
            return results
        }
        return freshResults
    }

    private func limitFallbackResults(
        _ results: [ReplyQueueResult],
        providerFailed: Bool
    ) -> [ReplyQueueResult] {
        guard providerFailed else { return results }

        let aiResults = results.filter { $0.source == "ai" }
        let fallbackResults = results
            .filter { $0.source != "ai" }
            .prefix(AppConstants.Search.ReplyQueue.maxFallbackRenderedResults)

        return sortReplyQueueResults(aiResults + fallbackResults)
    }

    private func localFallback(
        for pending: PendingChat,
        myUserId: Int64
    ) -> ReplyQueueTriageResultDTO {
        let classification: String
        let urgency: String
        let reason: String

        if pending.chat.chatType.isGroup {
            if pending.strictReplySignal {
                classification = ReplyQueueResult.Classification.onMe.rawValue
                urgency = "high"
                reason = "Recent group messages still look clearly directed at you."
            } else {
                classification = ReplyQueueResult.Classification.quiet.rawValue
                urgency = "low"
                reason = "No clear on-you group ask in recent context."
            }
        } else if pending.strictReplySignal {
            classification = ReplyQueueResult.Classification.onMe.rawValue
            urgency = "high"
            reason = "Recent DM context still clearly needs your reply."
        } else if pending.replyOwed {
            classification = ReplyQueueResult.Classification.onMe.rawValue
            urgency = "medium"
            reason = "Recent DM context probably still needs your reply."
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
            confidence: fallbackConfidence(
                classification: classification,
                pending: pending
            ),
            supportingMessageIds: supportingMessageIds(for: pending, myUserId: myUserId)
        )
    }

    private func fallbackConfidence(
        classification: String,
        pending: PendingChat
    ) -> Double {
        guard classification == ReplyQueueResult.Classification.onMe.rawValue else {
            return 0.42
        }

        if pending.chat.chatType.isGroup {
            return pending.strictReplySignal ? 0.79 : 0.64
        }

        if pending.strictReplySignal {
            return 0.83
        }
        if pending.replyOwed {
            return 0.70
        }
        return 0.58
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

    private func prioritizeEligibleChats(_ chats: [TGChat]) -> [TGChat] {
        let sortedPrivateChats = chats
            .filter { $0.chatType.isPrivate }
            .sorted(by: compareEligibleChats)
        let sortedGroupChats = chats
            .filter { $0.chatType.isGroup }
            .sorted(by: compareEligibleChats)
        let remainderChats = chats
            .filter { !$0.chatType.isPrivate && !$0.chatType.isGroup }
            .sorted(by: compareEligibleChats)

        guard !sortedPrivateChats.isEmpty, !sortedGroupChats.isEmpty else {
            return (sortedPrivateChats + sortedGroupChats + remainderChats)
        }

        var prioritized: [TGChat] = []
        prioritized.reserveCapacity(chats.count)

        var privateIndex = 0
        var groupIndex = 0
        let privateStride = 2

        while privateIndex < sortedPrivateChats.count || groupIndex < sortedGroupChats.count {
            for _ in 0..<privateStride where privateIndex < sortedPrivateChats.count {
                prioritized.append(sortedPrivateChats[privateIndex])
                privateIndex += 1
            }

            if groupIndex < sortedGroupChats.count {
                prioritized.append(sortedGroupChats[groupIndex])
                groupIndex += 1
            }

            if privateIndex >= sortedPrivateChats.count, groupIndex < sortedGroupChats.count {
                prioritized.append(contentsOf: sortedGroupChats[groupIndex...])
                break
            }

            if groupIndex >= sortedGroupChats.count, privateIndex < sortedPrivateChats.count {
                prioritized.append(contentsOf: sortedPrivateChats[privateIndex...])
                break
            }
        }

        prioritized.append(contentsOf: remainderChats)
        return prioritized
    }

    private func compareEligibleChats(_ lhs: TGChat, _ rhs: TGChat) -> Bool {
        let leftScore = eligibleChatPreRank(lhs)
        let rightScore = eligibleChatPreRank(rhs)
        if leftScore != rightScore { return leftScore > rightScore }
        let leftDate = lhs.lastMessage?.date ?? .distantPast
        let rightDate = rhs.lastMessage?.date ?? .distantPast
        if leftDate != rightDate { return leftDate > rightDate }
        return lhs.id < rhs.id
    }

    private func eligibleChatPreRank(_ chat: TGChat) -> Int {
        var score = 0
        if chat.chatType.isPrivate {
            score += 60
        } else if chat.chatType.isGroup {
            score += 28
        }

        if let lastDate = chat.lastMessage?.date {
            let age = Date().timeIntervalSince(lastDate)
            if age <= 86_400 { score += 24 }
            else if age <= 3 * 86_400 { score += 16 }
            else if age <= 7 * 86_400 { score += 8 }
        }

        score += min(chat.unreadCount, 5) * 3

        if chat.chatType.isGroup {
            let memberCount = chat.memberCount ?? 0
            if memberCount > 0 {
                if memberCount <= 6 { score += 10 }
                else if memberCount <= 12 { score += 5 }
                else { score -= 6 }
            }

            if chat.unreadCount > 3 {
                score -= 5
            }
        }

        return score
    }

    private func loadInitialMessagesLocally(for chats: [TGChat]) async -> [Int64: InitialBatchLoad] {
        await withTaskGroup(of: InitialBatchLoad.self) { group in
            for chat in chats {
                let limit = Self.initialMessageLimit(for: chat)
                group.addTask {
                    let loaded = await Self.loadLocalMessages(for: chat, limit: limit)
                    return InitialBatchLoad(
                        chatId: chat.id,
                        messages: loaded.messages,
                        source: loaded.source
                    )
                }
            }

            var loadedByChatId: [Int64: InitialBatchLoad] = [:]
            for await loaded in group {
                loadedByChatId[loaded.chatId] = loaded
            }
            return loadedByChatId
        }
    }

    nonisolated private static func initialMessageLimit(for chat: TGChat) -> Int {
        chat.chatType.isPrivate
            ? AppConstants.Search.ReplyQueue.initialPrivateMessagesPerChat
            : AppConstants.Search.ReplyQueue.initialGroupMessagesPerChat
    }

    nonisolated private static func loadLocalMessages(
        for chat: TGChat,
        limit: Int
    ) async -> (messages: [TGMessage], source: MessageCacheService.MessageLoadSource) {
        let loaded = await MessageCacheService.shared.getMessagesWithSource(chatId: chat.id)
        guard !loaded.messages.isEmpty else {
            return ([], .empty)
        }
        return (Array(loaded.messages.prefix(limit)), loaded.source)
    }

    private func elapsedMs(since start: Date) -> Int {
        Int((Date().timeIntervalSince(start) * 1000).rounded())
    }

    private func persistCandidateSnapshot(
        query: String,
        scope: QueryScope,
        providerName: String,
        providerModel: String,
        pending: [PendingChat],
        myUserId: Int64
    ) {
        let snapshot = PersistedReplyQueueCandidateSnapshot(
            query: query,
            scope: scope,
            providerName: providerName,
            providerModel: providerModel,
            capturedAt: Date(),
            candidates: pending.enumerated().map { index, item in
                PersistedReplyQueueCandidate(
                    order: index,
                    chatId: item.chat.id,
                    chatName: item.chat.title,
                    chatType: item.chat.chatType.displayName,
                    unreadCount: item.chat.unreadCount,
                    memberCount: item.chat.memberCount,
                    localSignal: localSignal(for: item),
                    pipelineHint: item.pipelineHint,
                    replyOwed: item.replyOwed,
                    strictReplySignal: item.strictReplySignal,
                    effectiveGroupReplySignal: item.effectiveGroupReplySignal,
                    messages: snippets(
                        for: item.messages,
                        chatTitle: item.chat.title,
                        myUserId: myUserId
                    )
                )
            }
        )

        Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601

            do {
                let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                let debugDirectory = appSupport
                    .appendingPathComponent(AppConstants.Storage.appSupportFolderName, isDirectory: true)
                    .appendingPathComponent("debug", isDirectory: true)
                try FileManager.default.createDirectory(at: debugDirectory, withIntermediateDirectories: true)
                let jsonURL = debugDirectory.appendingPathComponent("last_reply_queue_candidates.json", isDirectory: false)
                let data = try encoder.encode(snapshot)
                try data.write(to: jsonURL, options: [.atomic])
            } catch {
                // Ignore benchmark snapshot failures so search never fails.
            }
        }
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
