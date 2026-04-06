import Foundation

struct AgenticDebugExclusionBucket: Identifiable, Codable {
    let reason: String
    var count: Int = 0
    var sampleChats: [String] = []

    var id: String { reason }
}

struct AgenticDebugInfo: Codable {
    var scopedChats: Int
    var maxScanChats: Int
    var providerName: String = ""
    var providerModel: String = ""
    var scannedChats: Int = 0
    var inRangeChats: Int = 0
    var replyOwedChats: Int = 0
    var matchedChats: Int = 0
    var matchedPrivateChats: Int = 0
    var matchedGroupChats: Int = 0
    var candidatesSentToAI: Int = 0
    var aiReturned: Int = 0
    var rankedBeforeValidation: Int = 0
    var droppedByValidation: Int = 0
    var finalCount: Int = 0
    var finalPrivateChats: Int = 0
    var finalGroupChats: Int = 0
    var stopReason: String = "unknown"
    var exclusionBuckets: [AgenticDebugExclusionBucket] = []

    mutating func recordExclusion(_ reason: String, chatTitle: String) {
        if let index = exclusionBuckets.firstIndex(where: { $0.reason == reason }) {
            exclusionBuckets[index].count += 1
            if exclusionBuckets[index].sampleChats.count < 3,
               !exclusionBuckets[index].sampleChats.contains(chatTitle) {
                exclusionBuckets[index].sampleChats.append(chatTitle)
            }
        } else {
            exclusionBuckets.append(
                AgenticDebugExclusionBucket(
                    reason: reason,
                    count: 1,
                    sampleChats: chatTitle.isEmpty ? [] : [chatTitle]
                )
            )
        }
    }
}

struct AgenticDebugChatAudit: Identifiable, Codable {
    let chatId: Int64
    let chatTitle: String
    let chatType: String
    var scanned: Bool = false
    var inRange: Bool = false
    var messageCount: Int = 0
    var pipelineCategory: String = ""
    var replyOwed: Bool = false
    var strictReplySignal: Bool = false
    var effectiveGroupReplySignal: Bool = false
    var prefilterExclusionReason: String?
    var sentToAI: Bool = false
    var aiScore: Int?
    var aiWarmth: String?
    var aiReplyability: String?
    var aiConfidence: Double?
    var aiReason: String?
    var supportingMessageIds: [Int64] = []
    var validationFailureReason: String?
    var finalIncluded: Bool = false

    var id: Int64 { chatId }
}

private struct PersistedAgenticDebugSnapshot: Codable {
    let query: String
    let querySpec: QuerySpec?
    let capturedAt: Date
    let debug: AgenticDebugInfo
    let chatAudits: [AgenticDebugChatAudit]
}

private struct ReplyQueueTriageOutcome {
    let category: FollowUpItem.Category
    let suggestedAction: String
    let urgency: AIService.PipelineTriageResult.Urgency
    let confident: Bool
    let supportingMessageIds: [Int64]
    let source: String
}

private struct ReplyQueuePendingChat {
    let chat: TGChat
    let initialMessages: [TGMessage]
    let replyOwed: Bool
    let strictReplySignal: Bool
    let effectiveGroupReplySignal: Bool
}

extension SearchCoordinator {
    func executeAgenticSearch(
        query: String,
        querySpec: QuerySpec?,
        activeScope: QueryScope,
        aiSearchSourceChats: [TGChat],
        includeBotsInAISearch: Bool,
        telegramService: TelegramService,
        aiService: AIService,
        pipelineCategoryProvider: @escaping (Int64) -> FollowUpItem.Category?,
        pipelineHintProvider: @escaping (Int64) async -> String
    ) async throws -> [AISearchResult] {
        let constants = AppConstants.AI.AgenticSearch.self
        let resolvedQuerySpec = querySpec ?? queryInterpreter.parse(
            query: query,
            now: Date(),
            timezone: .current,
            activeFilter: activeScope
        )
        let replyQueueQuery = isReplyQueueQuery(query: query, querySpec: resolvedQuerySpec)
        let candidateCollection = await collectAgenticCandidateChats(
            scope: resolvedQuerySpec.scope,
            replyQueueQuery: replyQueueQuery,
            aiSearchSourceChats: aiSearchSourceChats,
            includeBotsInAISearch: includeBotsInAISearch,
            telegramService: telegramService
        )
        let rawScopedChats = candidateCollection.included
        let allChats = prioritizeAgenticChats(
            rawScopedChats,
            query: query,
            replyQueueQuery: replyQueueQuery,
            pipelineCategoryProvider: pipelineCategoryProvider
        )
        let maxScanChats = min(allChats.count, constants.maxAdaptiveScanChats)
        var debug = AgenticDebugInfo(
            scopedChats: allChats.count,
            maxScanChats: maxScanChats,
            providerName: aiService.providerType.rawValue,
            providerModel: aiService.providerModel
        )
        for exclusion in candidateCollection.exclusions {
            debug.recordExclusion(exclusion.reason, chatTitle: exclusion.chatTitle)
        }
        guard !allChats.isEmpty else {
            debug.stopReason = "no chats after scope/type prefilters"
            publishAgenticDebugInfo(debug, query: query, querySpec: resolvedQuerySpec)
            return []
        }

        let chatById = Dictionary(uniqueKeysWithValues: allChats.map { ($0.id, $0) })
        let myUserId = telegramService.currentUser?.id ?? 0
        let myUsername = telegramService.currentUser?.username

        if replyQueueQuery {
            return await executeReplyQueueTriageSearch(
                query: query,
                querySpec: resolvedQuerySpec,
                allChats: allChats,
                debug: debug,
                telegramService: telegramService,
                aiService: aiService,
                myUserId: myUserId,
                myUsername: myUsername
            )
        }

        let minimumScanChatsBeforeEarlyStop = replyQueueQuery
            ? min(maxScanChats, constants.replyQueueMinimumScanChats)
            : 0

        totalChatsToScan = maxScanChats
        semanticMatchedChats = 0
        currentQuerySpec = resolvedQuerySpec

        var candidateByChatId: [Int64: AgenticSearchCandidate] = [:]
        var latestRanked: [AgenticSearchResult] = []
        var scanOffset = 0
        var round = 0
        var previousTopIds: [Int64] = []
        var stableRounds = 0
        var providerFailed = false
        var providerFailureReason: String?
        var chatAudits: [Int64: AgenticDebugChatAudit] = [:]

        while scanOffset < maxScanChats && round < constants.maxAdaptiveRounds {
            let scanThisRound = round == 0 ? constants.initialScanChats : constants.adaptiveExpansionStep
            let remaining = maxScanChats - scanOffset
            let takeCount = min(scanThisRound, remaining)
            guard takeCount > 0 else { break }

            let roundChats = Array(allChats.dropFirst(scanOffset).prefix(takeCount))
            scanOffset += roundChats.count
            guard !roundChats.isEmpty else { break }

            for chat in roundChats {
                debug.scannedChats += 1
                var audit = chatAudits[chat.id] ?? AgenticDebugChatAudit(
                    chatId: chat.id,
                    chatTitle: chat.title,
                    chatType: chat.chatType.isPrivate ? "private" : (chat.chatType.isGroup ? "group" : "other")
                )
                audit.scanned = true
                let rawMessages = await cachedFirstMessages(
                    for: chat,
                    desiredCount: constants.initialMessagesPerChat,
                    timeRange: resolvedQuerySpec.timeRange,
                    telegramService: telegramService
                )
                let messages = applyTimeRange(rawMessages, timeRange: resolvedQuerySpec.timeRange)
                guard !messages.isEmpty else {
                    debug.recordExclusion("no messages in active date range", chatTitle: chat.title)
                    audit.prefilterExclusionReason = "no messages in active date range"
                    chatAudits[chat.id] = audit
                    continue
                }
                debug.inRangeChats += 1
                audit.inRange = true
                audit.messageCount = messages.count

                let pipelineHint = await pipelineHintProvider(chat.id)
                let effectivePipelineCategory = ConversationReplyHeuristics.resolvePipelineCategory(
                    for: chat,
                    hint: pipelineHint,
                    messages: messages,
                    myUserId: myUserId
                )
                let replyOwed = ConversationReplyHeuristics.isReplyOwed(
                    for: chat,
                    messages: messages,
                    myUserId: myUserId
                )
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
                audit.pipelineCategory = (replyQueueQuery && effectiveGroupReplySignal) || replyOwed
                    ? "on_me"
                    : effectivePipelineCategory
                audit.replyOwed = replyOwed
                audit.strictReplySignal = strictReplySignal
                audit.effectiveGroupReplySignal = effectiveGroupReplySignal
                if replyOwed {
                    debug.replyOwedChats += 1
                }

                if let exclusionReason = chatExclusionReasonForAgenticQuery(
                    chat: chat,
                    messages: messages,
                    query: query,
                    pipelineHint: effectivePipelineCategory,
                    replyOwed: replyOwed,
                    strictReplySignal: effectiveGroupReplySignal,
                    querySpec: resolvedQuerySpec
                ) {
                    debug.recordExclusion(exclusionReason, chatTitle: chat.title)
                    audit.prefilterExclusionReason = exclusionReason
                    chatAudits[chat.id] = audit
                    continue
                }
                debug.matchedChats += 1
                if chat.chatType.isPrivate {
                    debug.matchedPrivateChats += 1
                } else if chat.chatType.isGroup {
                    debug.matchedGroupChats += 1
                }

                candidateByChatId[chat.id] = AgenticSearchCandidate(
                    chat: chat,
                    pipelineCategory: audit.pipelineCategory,
                    strictReplySignal: strictReplySignal,
                    messages: messages
                )
                chatAudits[chat.id] = audit
            }

            semanticMatchedChats = scanOffset

            let candidates = allChats
                .compactMap { candidateByChatId[$0.id] }
                .prefix(constants.maxCandidateChats)
                .map { $0 }
            debug.candidatesSentToAI = max(debug.candidatesSentToAI, candidates.count)
            for candidate in candidates {
                if var audit = chatAudits[candidate.chat.id] {
                    audit.sentToAI = true
                    chatAudits[candidate.chat.id] = audit
                }
            }

            if candidates.isEmpty {
                round += 1
                continue
            }

            let ranked: [AgenticSearchResult]
            if providerFailed {
                ranked = heuristicAgenticFallbackRanking(
                    query: query,
                    querySpec: resolvedQuerySpec,
                    candidates: candidates,
                    myUserId: myUserId,
                    myUsername: myUsername
                )
            } else {
                do {
                    ranked = try await aiService.agenticSearch(
                        query: query,
                        querySpec: resolvedQuerySpec,
                        candidates: candidates,
                        myUserId: myUserId
                    )
                } catch {
                    providerFailed = true
                    let reason = compactAIErrorReason(error)
                    providerFailureReason = reason.isEmpty
                        ? "agentic provider call failed"
                        : "agentic provider call failed: \(reason)"
                    ranked = heuristicAgenticFallbackRanking(
                        query: query,
                        querySpec: resolvedQuerySpec,
                        candidates: candidates,
                        myUserId: myUserId,
                        myUsername: myUsername
                    )
                }
            }

            latestRanked = ranked
            debug.aiReturned = max(debug.aiReturned, ranked.count)
            for result in ranked {
                if var audit = chatAudits[result.chatId] {
                    audit.aiScore = result.score
                    audit.aiWarmth = result.warmth.rawValue
                    audit.aiReplyability = result.replyability.rawValue
                    audit.aiConfidence = result.confidence
                    audit.aiReason = result.reason
                    audit.supportingMessageIds = result.supportingMessageIds
                    chatAudits[result.chatId] = audit
                }
            }
            let topIds = Array(ranked.prefix(5).map(\.chatId))
            let topCount = min(5, ranked.count)
            let avgTopConfidence: Double
            if topCount > 0 {
                avgTopConfidence = ranked.prefix(topCount).map(\.confidence).reduce(0, +) / Double(topCount)
            } else {
                avgTopConfidence = 0
            }
            let provisionalValidated = ranked.filter { result in
                hardConstraintFailureReason(
                    result: result,
                    candidateByChatId: candidateByChatId,
                    querySpec: resolvedQuerySpec,
                    myUserId: myUserId,
                    myUsername: myUsername
                ) == nil
            }
            let provisionalFinalCount = provisionalValidated.count
            let provisionalGroupCount = provisionalValidated.reduce(into: 0) { count, result in
                if candidateByChatId[result.chatId]?.chat.chatType.isGroup == true {
                    count += 1
                }
            }

            if !topIds.isEmpty {
                if topIds == previousTopIds {
                    stableRounds += 1
                } else {
                    stableRounds = 0
                    previousTopIds = topIds
                }
            }

            let foundEnoughCandidates = candidates.count >= constants.maxCandidateChats
            let confidenceGood = avgTopConfidence >= constants.confidentTopAverageThreshold && ranked.count >= 5
            let scannedEnoughForEarlyStop = scanOffset >= minimumScanChatsBeforeEarlyStop
            let replyQueueHasUsefulFinalSet: Bool
            if replyQueueQuery {
                let hasUsefulFinalCount = provisionalFinalCount >= constants.replyQueueMinimumFinalResults
                let groupsWereMatched = debug.matchedGroupChats > 0
                let groupsRepresented = provisionalGroupCount > 0
                replyQueueHasUsefulFinalSet = hasUsefulFinalCount && (!groupsWereMatched || groupsRepresented)
            } else {
                replyQueueHasUsefulFinalSet = true
            }
            if scannedEnoughForEarlyStop
                && replyQueueHasUsefulFinalSet
                && (confidenceGood || stableRounds >= 1 || (foundEnoughCandidates && round > 0)) {
                if confidenceGood {
                    debug.stopReason = "early stop after confidence threshold at \(scanOffset) scans with \(provisionalFinalCount) validated results"
                } else if stableRounds >= 1 {
                    debug.stopReason = "early stop after stable top results at \(scanOffset) scans with \(provisionalFinalCount) validated results"
                } else {
                    debug.stopReason = "early stop after filling candidate cap at \(scanOffset) scans with \(provisionalFinalCount) validated results"
                }
                break
            }

            round += 1
        }

        guard !latestRanked.isEmpty else {
            if debug.candidatesSentToAI == 0 {
                debug.stopReason = "no candidates reached AI reranker"
            } else {
                debug.stopReason = "AI reranker returned empty list"
            }
            publishAgenticDebugInfo(debug, query: query, querySpec: resolvedQuerySpec)
            return []
        }
        var rankedByChatId = Dictionary(uniqueKeysWithValues: latestRanked.map { ($0.chatId, $0) })

        let lowConfidence = latestRanked
            .filter { $0.confidence < constants.lowConfidenceThreshold }
            .prefix(constants.maxLowConfidenceTopUps)

        if !providerFailed, !lowConfidence.isEmpty {
            var topUpCandidates: [AgenticSearchCandidate] = []
            for result in lowConfidence {
                guard let chat = chatById[result.chatId] else { continue }
                let baseMessages = await cachedFirstMessages(
                    for: chat,
                    desiredCount: constants.initialMessagesPerChat,
                    timeRange: resolvedQuerySpec.timeRange,
                    telegramService: telegramService
                )
                let filteredBase = applyTimeRange(baseMessages, timeRange: resolvedQuerySpec.timeRange)
                guard !filteredBase.isEmpty else { continue }
                let pipelineHint = await pipelineHintProvider(chat.id)
                let effectivePipelineCategory = ConversationReplyHeuristics.resolvePipelineCategory(
                    for: chat,
                    hint: pipelineHint,
                    messages: filteredBase,
                    myUserId: myUserId
                )
                let replyOwed = ConversationReplyHeuristics.isReplyOwed(
                    for: chat,
                    messages: filteredBase,
                    myUserId: myUserId
                )
                let strictReplySignal = ConversationReplyHeuristics.hasStrictReplyOpportunity(
                    chat: chat,
                    messages: filteredBase,
                    myUserId: myUserId,
                    myUsername: myUsername
                )
                let effectiveGroupReplySignal = strictReplySignal || ConversationReplyHeuristics.hasLikelyDirectedGroupReplyOpportunity(
                    chat: chat,
                    messages: filteredBase,
                    myUserId: myUserId,
                    myUsername: myUsername
                )

                let expanded = await topUpOlderMessages(
                    for: chat,
                    existingMessages: filteredBase,
                    additionalCount: constants.topUpAdditionalMessages,
                    maxTotal: constants.maxMessagesPerChat,
                    timeRange: resolvedQuerySpec.timeRange,
                    telegramService: telegramService
                )
                let filteredExpanded = applyTimeRange(expanded, timeRange: resolvedQuerySpec.timeRange)
                guard filteredExpanded.count > filteredBase.count else { continue }

                let topUpCandidate = AgenticSearchCandidate(
                    chat: chat,
                    pipelineCategory: (replyQueueQuery && effectiveGroupReplySignal) || replyOwed
                        ? "on_me"
                        : effectivePipelineCategory,
                    strictReplySignal: strictReplySignal,
                    messages: filteredExpanded
                )
                candidateByChatId[chat.id] = topUpCandidate
                topUpCandidates.append(topUpCandidate)
            }

            if !topUpCandidates.isEmpty,
               let refined = try? await aiService.agenticSearch(
                    query: query,
                    querySpec: resolvedQuerySpec,
                    candidates: topUpCandidates,
                    myUserId: myUserId
               ) {
                debug.aiReturned = max(debug.aiReturned, refined.count)
                for item in refined {
                    rankedByChatId[item.chatId] = item
                }
            }
        }

        let rankedBeforeValidation = rankedByChatId.values
            .sorted { $0.score > $1.score }
        debug.rankedBeforeValidation = rankedBeforeValidation.count

        let validatedRanked = rankedBeforeValidation
            .filter { result in
                if let failureReason = hardConstraintFailureReason(
                    result: result,
                    candidateByChatId: candidateByChatId,
                    querySpec: resolvedQuerySpec,
                    myUserId: myUserId,
                    myUsername: myUsername
                ) {
                    if let candidate = candidateByChatId[result.chatId] {
                        debug.recordExclusion(failureReason, chatTitle: candidate.chat.title)
                    }
                    if var audit = chatAudits[result.chatId] {
                        audit.validationFailureReason = failureReason
                        chatAudits[result.chatId] = audit
                    }
                    return false
                }
                if var audit = chatAudits[result.chatId] {
                    audit.finalIncluded = true
                    chatAudits[result.chatId] = audit
                }
                return true
            }
        debug.droppedByValidation = max(0, rankedBeforeValidation.count - validatedRanked.count)

        let finalRanked = validatedRanked
            .prefix(constants.maxCandidateChats)
            .map { $0 }
        debug.finalCount = finalRanked.count
        debug.finalPrivateChats = finalRanked.reduce(into: 0) { count, result in
            if candidateByChatId[result.chatId]?.chat.chatType.isPrivate == true {
                count += 1
            }
        }
        debug.finalGroupChats = finalRanked.reduce(into: 0) { count, result in
            if candidateByChatId[result.chatId]?.chat.chatType.isGroup == true {
                count += 1
            }
        }

        if finalRanked.isEmpty {
            if debug.rankedBeforeValidation > 0 {
                debug.stopReason = "all ranked results failed hard constraints"
            } else {
                debug.stopReason = "no ranked results before validation"
            }
            publishAgenticDebugInfo(debug, query: query, querySpec: resolvedQuerySpec)
            return []
        }

        if debug.stopReason == "unknown" {
            if scanOffset >= maxScanChats {
                debug.stopReason = "hit scan cap at \(scanOffset) chats"
            } else if round >= constants.maxAdaptiveRounds {
                debug.stopReason = "hit round limit after \(scanOffset) scans"
            } else {
                debug.stopReason = "ok"
            }
        }
        if let providerFailureReason {
            if debug.stopReason == "ok" {
                debug.stopReason = "\(providerFailureReason) • using local fallback"
            } else {
                debug.stopReason = "\(providerFailureReason) • using local fallback • \(debug.stopReason)"
            }
        }
        publishAgenticDebugInfo(
            debug,
            chatAudits: Array(chatAudits.values).sorted { lhs, rhs in
                if lhs.finalIncluded != rhs.finalIncluded {
                    return lhs.finalIncluded && !rhs.finalIncluded
                }
                if lhs.sentToAI != rhs.sentToAI {
                    return lhs.sentToAI && !rhs.sentToAI
                }
                let lhsScore = lhs.aiScore ?? -1
                let rhsScore = rhs.aiScore ?? -1
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                return lhs.chatTitle.localizedCaseInsensitiveCompare(rhs.chatTitle) == .orderedAscending
            },
            query: query,
            querySpec: resolvedQuerySpec
        )
        return finalRanked.map { .agenticResult($0) }
    }

    private func publishAgenticDebugInfo(
        _ debug: AgenticDebugInfo,
        chatAudits: [AgenticDebugChatAudit] = [],
        query: String,
        querySpec: QuerySpec
    ) {
        agenticDebugInfo = debug
        persistAgenticDebugSnapshot(
            PersistedAgenticDebugSnapshot(
                query: query,
                querySpec: querySpec,
                capturedAt: Date(),
                debug: debug,
                chatAudits: chatAudits
            )
        )
    }

    private func persistAgenticDebugSnapshot(_ snapshot: PersistedAgenticDebugSnapshot) {
        Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                return
            }

            let debugDirectory = appSupport
                .appendingPathComponent(AppConstants.Storage.appSupportFolderName, isDirectory: true)
                .appendingPathComponent("debug", isDirectory: true)
            let jsonURL = debugDirectory.appendingPathComponent("last_agentic_debug.json", isDirectory: false)
            let textURL = debugDirectory.appendingPathComponent("last_agentic_debug.txt", isDirectory: false)

            do {
                try fileManager.createDirectory(at: debugDirectory, withIntermediateDirectories: true)

                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let jsonData = try encoder.encode(snapshot)
                try jsonData.write(to: jsonURL, options: .atomic)

                let formatter = ISO8601DateFormatter()
                var lines: [String] = [
                    "query: \(snapshot.query)",
                    "capturedAt: \(formatter.string(from: snapshot.capturedAt))"
                ]
                if let querySpec = snapshot.querySpec {
                    lines.append("scope: \(querySpec.scope.rawValue) • replyConstraint: \(querySpec.replyConstraint.rawValue)")
                    if let timeRange = querySpec.timeRange {
                        lines.append("timeRange: \(timeRange.label)")
                    }
                }
                lines.append("")
                lines.append("provider \(snapshot.debug.providerName) • model \(snapshot.debug.providerModel)")
                lines.append("scoped \(snapshot.debug.scopedChats) • scanCap \(snapshot.debug.maxScanChats) • scanned \(snapshot.debug.scannedChats)")
                lines.append("inRange \(snapshot.debug.inRangeChats) • replyOwed \(snapshot.debug.replyOwedChats) • queryMatch \(snapshot.debug.matchedChats)")
                lines.append("matchedDMs \(snapshot.debug.matchedPrivateChats) • matchedGroups \(snapshot.debug.matchedGroupChats) • finalDMs \(snapshot.debug.finalPrivateChats) • finalGroups \(snapshot.debug.finalGroupChats)")
                lines.append("toAI \(snapshot.debug.candidatesSentToAI) • aiReturned \(snapshot.debug.aiReturned) • ranked \(snapshot.debug.rankedBeforeValidation)")
                lines.append("dropped \(snapshot.debug.droppedByValidation) • final \(snapshot.debug.finalCount) • reason \(snapshot.debug.stopReason)")

                if !snapshot.debug.exclusionBuckets.isEmpty {
                    lines.append("")
                    lines.append("Excluded")
                    for bucket in snapshot.debug.exclusionBuckets.sorted(by: { lhs, rhs in
                        if lhs.count == rhs.count { return lhs.reason < rhs.reason }
                        return lhs.count > rhs.count
                    }) {
                        lines.append("\(bucket.reason) • \(bucket.count)")
                        if !bucket.sampleChats.isEmpty {
                            lines.append(bucket.sampleChats.joined(separator: ", "))
                        }
                    }
                }

                if !snapshot.chatAudits.isEmpty {
                    lines.append("")
                    lines.append("ChatAudits")
                    for audit in snapshot.chatAudits.prefix(40) {
                        let aiSummary = audit.sentToAI
                            ? "sentToAI=\(audit.sentToAI) aiReplyability=\(audit.aiReplyability ?? "-") aiScore=\(audit.aiScore.map(String.init) ?? "-")"
                            : "sentToAI=false"
                        let validation = audit.validationFailureReason ?? (audit.finalIncluded ? "final" : audit.prefilterExclusionReason ?? "-")
                        lines.append("[\(audit.chatType)] \(audit.chatTitle) • pipeline=\(audit.pipelineCategory) • replyOwed=\(audit.replyOwed) • strict=\(audit.strictReplySignal) • groupDirected=\(audit.effectiveGroupReplySignal) • \(aiSummary) • outcome=\(validation)")
                    }
                }

                try lines.joined(separator: "\n").write(to: textURL, atomically: true, encoding: .utf8)
            } catch {
                print("[AgenticDebug] Failed to persist debug snapshot: \(error)")
            }
        }
    }

    private func isReplyQueueQuery(query: String, querySpec: QuerySpec) -> Bool {
        guard querySpec.replyConstraint == .pipelineOnMeOnly else { return false }

        let normalized = query.lowercased()
        let replySignals = [
            "reply",
            "respond",
            "have to reply",
            "need to reply",
            "who do i",
            "who should i",
            "follow up",
            "follow-up"
        ]
        return replySignals.contains(where: { normalized.contains($0) })
    }

    private func prioritizeAgenticChats(
        _ chats: [TGChat],
        query: String,
        replyQueueQuery: Bool,
        pipelineCategoryProvider: (Int64) -> FollowUpItem.Category?
    ) -> [TGChat] {
        let normalizedQuery = query.lowercased()
        let tokens = normalizedQuery
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 }
        let now = Date()

        let sortedChats = chats.sorted { a, b in
            func score(_ chat: TGChat) -> Int {
                let title = chat.title.lowercased()
                let preview = chat.lastMessage?.displayText.lowercased() ?? ""
                var total = 0

                if !replyQueueQuery {
                    if title.contains(normalizedQuery) { total += 30 }
                    for token in tokens {
                        if title.contains(token) { total += 8 }
                        if preview.contains(token) { total += 5 }
                    }
                }

                if let status = pipelineCategoryProvider(chat.id) {
                    switch status {
                    case .onMe: total += 12
                    case .onThem: total += 4
                    case .quiet: break
                    }
                }

                if chat.unreadCount > 0 { total += 6 }

                if replyQueueQuery {
                    if chat.chatType.isPrivate {
                        total += 16
                    } else {
                        total -= 6
                    }

                    if let memberCount = chat.memberCount, memberCount > 8 {
                        total -= min(8, memberCount / 3)
                    }
                }

                if let lastDate = chat.lastMessage?.date {
                    let age = now.timeIntervalSince(lastDate)
                    if age <= 86_400 { total += 8 }
                    else if age <= 259_200 { total += 4 }
                }

                return total
            }

            let left = score(a)
            let right = score(b)
            if left != right { return left > right }
            return a.order > b.order
        }

        guard replyQueueQuery else { return sortedChats }

        var privateChats = sortedChats.filter { $0.chatType.isPrivate }
        var groupChats = sortedChats.filter { $0.chatType.isGroup }
        guard !privateChats.isEmpty, !groupChats.isEmpty else { return sortedChats }

        var mixed: [TGChat] = []
        mixed.reserveCapacity(sortedChats.count)

        while !privateChats.isEmpty || !groupChats.isEmpty {
            for _ in 0..<2 {
                if !privateChats.isEmpty {
                    mixed.append(privateChats.removeFirst())
                }
            }
            if !groupChats.isEmpty {
                mixed.append(groupChats.removeFirst())
            }
            if privateChats.isEmpty, !groupChats.isEmpty {
                mixed.append(contentsOf: groupChats)
                break
            }
            if groupChats.isEmpty, !privateChats.isEmpty {
                mixed.append(contentsOf: privateChats)
                break
            }
        }

        return mixed
    }

    private func chatExclusionReasonForAgenticQuery(
        chat: TGChat,
        messages: [TGMessage],
        query: String,
        pipelineHint: String,
        replyOwed: Bool,
        strictReplySignal: Bool,
        querySpec: QuerySpec
    ) -> String? {
        if querySpec.replyConstraint == .pipelineOnMeOnly {
            if chat.chatType.isPrivate {
                return (strictReplySignal || replyOwed || pipelineHint == "on_me")
                    ? nil
                    : "dm not clearly on you"
            }
            return strictReplySignal ? nil : "group not clearly directed at you"
        }

        let normalizedQuery = query.lowercased()
        let stopWords: Set<String> = [
            "who", "what", "when", "where", "why", "how", "have", "has", "had",
            "with", "that", "this", "from", "your", "you", "for", "the", "and",
            "are", "was", "were", "can", "could", "would", "should", "about"
        ]
        let tokens = normalizedQuery
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 && !stopWords.contains($0) }

        let corpus = (
            [chat.title.lowercased(), chat.lastMessage?.displayText.lowercased() ?? ""]
            + messages.prefix(8).map { $0.displayText.lowercased() }
        ).joined(separator: " ")

        let tokenMatches = tokens.filter { corpus.contains($0) }.count
        if tokenMatches >= max(1, min(2, tokens.count)) {
            return nil
        }

        let isReplyIntent =
            normalizedQuery.contains("reply")
            || normalizedQuery.contains("respond")
            || normalizedQuery.contains("follow up")
            || normalizedQuery.contains("follow-up")
            || normalizedQuery.contains("waiting on me")
            || normalizedQuery.contains("who do i")
            || normalizedQuery.contains("who should i")
            || normalizedQuery.contains("have to reply")

        if isReplyIntent {
            if chat.chatType.isPrivate, (pipelineHint == "on_me" || replyOwed || strictReplySignal) {
                return nil
            }
            if strictReplySignal { return nil }
            return "no strong reply signal"
        }

        if normalizedQuery.contains("intro") || normalizedQuery.contains("connect") {
            if corpus.contains("intro") || corpus.contains("connect") {
                return nil
            }
        }

        return "did not match query intent"
    }

    private func applyTimeRange(_ messages: [TGMessage], timeRange: TimeRangeConstraint?) -> [TGMessage] {
        guard let timeRange else { return messages }
        return messages.filter { timeRange.contains($0.date) }
    }

    private func chatMatchesScope(_ chat: TGChat, scope: QueryScope) -> Bool {
        switch scope {
        case .all:
            return chat.chatType.isPrivate || chat.chatType.isGroup
        case .dms:
            return chat.chatType.isPrivate
        case .groups:
            return chat.chatType.isGroup
        }
    }

    private func hardConstraintFailureReason(
        result: AgenticSearchResult,
        candidateByChatId: [Int64: AgenticSearchCandidate],
        querySpec: QuerySpec,
        myUserId: Int64,
        myUsername: String?
    ) -> String? {
        guard let candidate = candidateByChatId[result.chatId] else { return "missing candidate context" }

        if !chatMatchesScope(candidate.chat, scope: querySpec.scope) {
            return "failed scope validation"
        }

        if querySpec.replyConstraint == .pipelineOnMeOnly {
            let strictReplySignal = candidate.strictReplySignal || ConversationReplyHeuristics.hasStrictReplyOpportunity(
                chat: candidate.chat,
                messages: candidate.messages,
                myUserId: myUserId,
                myUsername: myUsername
            )
            let effectiveGroupReplySignal = strictReplySignal || ConversationReplyHeuristics.hasLikelyDirectedGroupReplyOpportunity(
                chat: candidate.chat,
                messages: candidate.messages,
                myUserId: myUserId,
                myUsername: myUsername
            )

            guard result.replyability == .replyNow else {
                return "not marked reply_now"
            }

            if candidate.chat.chatType.isGroup {
                return effectiveGroupReplySignal ? nil : "group not clearly directed at you"
            }

            if !strictReplySignal && candidate.pipelineCategory != "on_me" {
                return "dm lost on_me validation"
            }
        }

        if let timeRange = querySpec.timeRange,
           !candidate.messages.contains(where: { timeRange.contains($0.date) }) {
            return "no messages in active date range"
        }

        return nil
    }

    private func collectAgenticCandidateChats(
        scope: QueryScope,
        replyQueueQuery: Bool,
        aiSearchSourceChats: [TGChat],
        includeBotsInAISearch: Bool,
        telegramService: TelegramService
    ) async -> (included: [TGChat], exclusions: [(reason: String, chatTitle: String)]) {
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

            included.append(chat)
        }

        guard !includeBotsInAISearch else { return (included, exclusions) }

        var filtered: [TGChat] = []
        filtered.reserveCapacity(included.count)
        for chat in included {
            if await telegramService.isBotChat(chat) {
                exclusions.append(("bot filtered", chat.title))
                continue
            }
            filtered.append(chat)
        }
        return (filtered, exclusions)
    }

    private func executeReplyQueueTriageSearch(
        query: String,
        querySpec: QuerySpec,
        allChats: [TGChat],
        debug initialDebug: AgenticDebugInfo,
        telegramService: TelegramService,
        aiService: AIService,
        myUserId: Int64,
        myUsername: String?
    ) async -> [AISearchResult] {
        var debug = initialDebug
        var chatAudits: [Int64: AgenticDebugChatAudit] = [:]
        var finalResults: [AgenticSearchResult] = []
        var fallbackCount = 0
        var pendingChats: [ReplyQueuePendingChat] = []

        totalChatsToScan = allChats.count
        semanticMatchedChats = 0
        currentQuerySpec = querySpec

        for chat in allChats {
            debug.scannedChats += 1
            semanticMatchedChats = debug.scannedChats

            var audit = AgenticDebugChatAudit(
                chatId: chat.id,
                chatTitle: chat.title,
                chatType: chat.chatType.isPrivate ? "private" : (chat.chatType.isGroup ? "group" : "other")
            )
            audit.scanned = true

            let initialMessages = await cachedFirstMessages(
                for: chat,
                desiredCount: AppConstants.FollowUp.messagesPerChat,
                timeRange: querySpec.timeRange,
                telegramService: telegramService
            )

            guard !initialMessages.isEmpty else {
                debug.recordExclusion("no messages in active date range", chatTitle: chat.title)
                audit.prefilterExclusionReason = "no messages in active date range"
                chatAudits[chat.id] = audit
                continue
            }

            debug.inRangeChats += 1
            audit.inRange = true
            audit.messageCount = initialMessages.count

            let replyOwed = ConversationReplyHeuristics.isReplyOwed(
                for: chat,
                messages: initialMessages,
                myUserId: myUserId
            )
            let strictReplySignal = ConversationReplyHeuristics.hasStrictReplyOpportunity(
                chat: chat,
                messages: initialMessages,
                myUserId: myUserId,
                myUsername: myUsername
            )
            let effectiveGroupReplySignal = strictReplySignal || ConversationReplyHeuristics.hasLikelyDirectedGroupReplyOpportunity(
                chat: chat,
                messages: initialMessages,
                myUserId: myUserId,
                myUsername: myUsername
            )

            audit.replyOwed = replyOwed
            audit.strictReplySignal = strictReplySignal
            audit.effectiveGroupReplySignal = effectiveGroupReplySignal
            audit.pipelineCategory = (replyOwed || effectiveGroupReplySignal) ? "on_me" : "quiet"
            chatAudits[chat.id] = audit

            if replyOwed {
                debug.replyOwedChats += 1
            }

            pendingChats.append(
                ReplyQueuePendingChat(
                    chat: chat,
                    initialMessages: initialMessages,
                    replyOwed: replyOwed,
                    strictReplySignal: strictReplySignal,
                    effectiveGroupReplySignal: effectiveGroupReplySignal
                )
            )
        }

        let concurrency = max(1, AppConstants.FollowUp.maxAIConcurrency)
        var index = 0
        while index < pendingChats.count {
            let upperBound = min(index + concurrency, pendingChats.count)
            let batch = Array(pendingChats[index..<upperBound])
            index = upperBound

            let triagedBatch = await withTaskGroup(of: (Int64, ReplyQueueTriageOutcome).self) { group in
                for pending in batch {
                    group.addTask {
                        let triage = await self.triageReplyQueueChat(
                            chat: pending.chat,
                            initialMessages: pending.initialMessages,
                            querySpec: querySpec,
                            telegramService: telegramService,
                            aiService: aiService,
                            myUserId: myUserId
                        )
                        return (pending.chat.id, triage)
                    }
                }

                var results: [Int64: ReplyQueueTriageOutcome] = [:]
                for await (chatId, triage) in group {
                    results[chatId] = triage
                }
                return results
            }

            for pending in batch {
                guard let triage = triagedBatch[pending.chat.id] else { continue }
                var audit = chatAudits[pending.chat.id] ?? AgenticDebugChatAudit(
                    chatId: pending.chat.id,
                    chatTitle: pending.chat.title,
                    chatType: pending.chat.chatType.isPrivate ? "private" : (pending.chat.chatType.isGroup ? "group" : "other")
                )
                audit.sentToAI = true
                debug.candidatesSentToAI += 1
                debug.aiReturned += 1

                let aiReplyability: AgenticSearchResult.Replyability
                switch triage.category {
                case .onMe:
                    aiReplyability = .replyNow
                case .onThem:
                    aiReplyability = .waitingOnThem
                case .quiet:
                    aiReplyability = .unclear
                }

                let triageScore = scoreForReplyQueueOutcome(
                    chat: pending.chat,
                    category: triage.category,
                    urgency: triage.urgency,
                    confident: triage.confident,
                    replyOwed: pending.replyOwed,
                    strictReplySignal: pending.strictReplySignal,
                    effectiveGroupReplySignal: pending.effectiveGroupReplySignal,
                    source: triage.source
                )
                let warmth = warmthForReplyQueueScore(triageScore)

                audit.aiReplyability = aiReplyability.rawValue
                audit.aiScore = triageScore
                audit.aiWarmth = warmth.rawValue
                audit.aiConfidence = triage.confident ? 0.85 : 0.62
                audit.aiReason = triage.suggestedAction
                audit.supportingMessageIds = triage.supportingMessageIds

                if triage.source != "ai" {
                    fallbackCount += 1
                }

                guard triage.category == .onMe else {
                    let exclusionReason: String
                    switch triage.category {
                    case .onThem:
                        exclusionReason = "ai triaged on_them"
                    case .quiet:
                        exclusionReason = "ai triaged quiet"
                    case .onMe:
                        exclusionReason = "quiet"
                    }
                    debug.recordExclusion(exclusionReason, chatTitle: pending.chat.title)
                    audit.validationFailureReason = exclusionReason
                    chatAudits[pending.chat.id] = audit
                    continue
                }

                debug.matchedChats += 1
                if pending.chat.chatType.isPrivate {
                    debug.matchedPrivateChats += 1
                } else if pending.chat.chatType.isGroup {
                    debug.matchedGroupChats += 1
                }

                let result = AgenticSearchResult(
                    chatId: pending.chat.id,
                    chatTitle: pending.chat.title,
                    score: triageScore,
                    warmth: warmth,
                    replyability: .replyNow,
                    reason: triage.suggestedAction,
                    suggestedAction: triage.suggestedAction,
                    confidence: triage.confident ? 0.85 : 0.62,
                    supportingMessageIds: triage.supportingMessageIds
                )
                finalResults.append(result)
                audit.finalIncluded = true
                chatAudits[pending.chat.id] = audit
            }
        }

        finalResults.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.chatTitle.localizedCaseInsensitiveCompare(rhs.chatTitle) == .orderedAscending
        }

        debug.rankedBeforeValidation = finalResults.count
        debug.finalCount = finalResults.count
        debug.finalPrivateChats = finalResults.reduce(into: 0) { count, result in
            if let audit = chatAudits[result.chatId], audit.chatType == "private" {
                count += 1
            }
        }
        debug.finalGroupChats = finalResults.reduce(into: 0) { count, result in
            if let audit = chatAudits[result.chatId], audit.chatType == "group" {
                count += 1
            }
        }
        debug.stopReason = fallbackCount > 0
            ? "triaged all eligible chats • \(fallbackCount) local fallback\(fallbackCount == 1 ? "" : "s")"
            : "triaged all eligible chats"

        publishAgenticDebugInfo(
            debug,
            chatAudits: Array(chatAudits.values).sorted { lhs, rhs in
                if lhs.finalIncluded != rhs.finalIncluded {
                    return lhs.finalIncluded && !rhs.finalIncluded
                }
                let lhsScore = lhs.aiScore ?? -1
                let rhsScore = rhs.aiScore ?? -1
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                return lhs.chatTitle.localizedCaseInsensitiveCompare(rhs.chatTitle) == .orderedAscending
            },
            query: query,
            querySpec: querySpec
        )

        return finalResults.map { .agenticResult($0) }
    }

    private func triageReplyQueueChat(
        chat: TGChat,
        initialMessages: [TGMessage],
        querySpec: QuerySpec,
        telegramService: TelegramService,
        aiService: AIService,
        myUserId: Int64
    ) async -> ReplyQueueTriageOutcome {
        let cache = MessageCacheService.shared
        let maxMessages = AppConstants.FollowUp.maxMessagesForAIClassification
        let defaultNeedMoreMessages = max(10, AppConstants.FollowUp.progressiveFetchStep * 2)
        let myUser = telegramService.currentUser
        var allMessages = initialMessages.sorted { $0.date > $1.date }
        var currentWindowSize = min(AppConstants.FollowUp.messagesPerChat, allMessages.count)

        func expandWindow(toAtLeast target: Int) async -> Bool {
            guard target > currentWindowSize else { return false }

            while allMessages.count < target {
                let remaining = target - allMessages.count
                let fetchLimit = min(max(AppConstants.FollowUp.progressiveFetchStep, 1), remaining)
                guard fetchLimit > 0 else { break }

                let oldestId = allMessages.last?.id ?? 0
                guard oldestId != 0 else { break }

                do {
                    let moreMsgs = try await telegramService.getChatHistory(
                        chatId: chat.id,
                        fromMessageId: oldestId,
                        limit: fetchLimit
                    )
                    guard !moreMsgs.isEmpty else { break }
                    allMessages.append(contentsOf: moreMsgs)
                    allMessages.sort { $0.date > $1.date }
                    await cache.cacheMessages(chatId: chat.id, messages: moreMsgs, append: true)
                } catch {
                    break
                }
            }

            let filtered = applyTimeRange(allMessages, timeRange: querySpec.timeRange)
            let updatedWindowSize = min(target, filtered.count)
            guard updatedWindowSize > currentWindowSize else { return false }
            currentWindowSize = updatedWindowSize
            allMessages = filtered
            return true
        }

        var attempt = 0
        while attempt < 2 {
            attempt += 1
            let messagesToSend = Array(allMessages.prefix(currentWindowSize))

            do {
                let triage = try await aiService.categorizePipelineChat(
                    chat: chat,
                    messages: messagesToSend,
                    myUserId: myUserId,
                    myUser: myUser
                )

                switch triage.status {
                case .needMore:
                    guard attempt == 1 else { break }
                    let requested = triage.additionalMessages ?? defaultNeedMoreMessages
                    let boundedAdditional = max(10, min(defaultNeedMoreMessages, requested))
                    let targetWindowSize = min(maxMessages, currentWindowSize + boundedAdditional)
                    let expanded = await expandWindow(toAtLeast: targetWindowSize)
                    guard expanded else { break }
                    continue

                case .decision:
                    let normalizedCategory = ConversationReplyHeuristics.normalizePipelineCategory(
                        proposed: triage.category,
                        suggestedAction: triage.suggestedAction,
                        chat: chat,
                        messages: messagesToSend,
                        myUserId: myUserId
                    )
                    let finalSuggestion = normalizedReplyQueueSuggestion(
                        category: normalizedCategory,
                        suggestedAction: triage.suggestedAction,
                        chat: chat,
                        messages: messagesToSend,
                        myUserId: myUserId
                    )
                    let needsConfidenceRetry = !triage.confident && attempt == 1 && currentWindowSize < maxMessages
                    if needsConfidenceRetry {
                        let targetWindowSize = min(maxMessages, currentWindowSize + defaultNeedMoreMessages)
                        let expanded = await expandWindow(toAtLeast: targetWindowSize)
                        guard expanded else { break }
                        continue
                    }

                    if let lastMessage = chat.lastMessage {
                        await cache.cachePipelineCategory(
                            chatId: chat.id,
                            category: pipelineCategoryString(normalizedCategory),
                            suggestedAction: finalSuggestion,
                            lastMessageId: lastMessage.id
                        )
                    }

                    return ReplyQueueTriageOutcome(
                        category: normalizedCategory,
                        suggestedAction: finalSuggestion,
                        urgency: triage.urgency,
                        confident: triage.confident,
                        supportingMessageIds: supportingMessageIdsForReplyQueue(messages: messagesToSend, myUserId: myUserId),
                        source: "ai"
                    )
                }
            } catch {
                break
            }
        }

        let fallbackWindow = Array(allMessages.prefix(currentWindowSize))
        let fallbackCategoryHint = ConversationReplyHeuristics.resolvePipelineCategory(
            for: chat,
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
        let fallbackSuggestion = normalizedReplyQueueSuggestion(
            category: fallbackCategory,
            suggestedAction: "",
            chat: chat,
            messages: fallbackWindow,
            myUserId: myUserId
        )

        return ReplyQueueTriageOutcome(
            category: fallbackCategory,
            suggestedAction: fallbackSuggestion,
            urgency: fallbackCategory == .onMe ? .high : .low,
            confident: false,
            supportingMessageIds: supportingMessageIdsForReplyQueue(messages: fallbackWindow, myUserId: myUserId),
            source: "fallback"
        )
    }

    private func normalizedReplyQueueSuggestion(
        category: FollowUpItem.Category,
        suggestedAction: String,
        chat: TGChat,
        messages: [TGMessage],
        myUserId: Int64
    ) -> String {
        let trimmed = suggestedAction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }

        switch category {
        case .onMe:
            if let latestInbound = ConversationReplyHeuristics.latestInboundRequiringReply(
                chat: chat,
                messages: messages,
                myUserId: myUserId
            ) {
                let sender = latestInbound.senderName?.split(separator: " ").first.map(String.init) ?? "them"
                let snippet = compactFallbackSnippet(latestInbound.textContent)
                if !snippet.isEmpty {
                    return "Reply to \(sender) on \"\(snippet)\" with a concrete next step."
                }
            }
            return "Reply with a concrete next step."
        case .onThem:
            return "Wait for their update."
        case .quiet:
            return ""
        }
    }

    private func supportingMessageIdsForReplyQueue(messages: [TGMessage], myUserId: Int64) -> [Int64] {
        let sorted = messages.sorted { $0.date > $1.date }
        var ids: [Int64] = []
        if let inbound = sorted.first(where: { !ConversationReplyHeuristics.messageIsFromMe($0, myUserId: myUserId) }) {
            ids.append(inbound.id)
        }
        if let outbound = sorted.first(where: { ConversationReplyHeuristics.messageIsFromMe($0, myUserId: myUserId) }),
           !ids.contains(outbound.id) {
            ids.append(outbound.id)
        }
        if ids.isEmpty {
            ids = sorted.prefix(2).map(\.id)
        }
        return Array(ids.prefix(2))
    }

    private func scoreForReplyQueueOutcome(
        chat: TGChat,
        category: FollowUpItem.Category,
        urgency: AIService.PipelineTriageResult.Urgency,
        confident: Bool,
        replyOwed: Bool,
        strictReplySignal: Bool,
        effectiveGroupReplySignal: Bool,
        source: String
    ) -> Int {
        var score: Int
        switch category {
        case .onMe:
            score = urgency == .high ? 84 : 70
        case .onThem:
            score = 42
        case .quiet:
            score = 18
        }

        if chat.chatType.isPrivate {
            score += 6
        } else if chat.chatType.isGroup {
            score += effectiveGroupReplySignal ? 4 : 0
        }

        if replyOwed { score += 6 }
        if strictReplySignal { score += 6 }
        if chat.unreadCount > 0 { score += 3 }
        if !confident { score -= 8 }
        if source != "ai" { score -= 10 }

        if let lastDate = chat.lastMessage?.date {
            let age = Date().timeIntervalSince(lastDate)
            if age <= 86_400 {
                score += 6
            } else if age <= 3 * 86_400 {
                score += 3
            } else if age <= 7 * 86_400 {
                score += 1
            }
        }

        return max(1, min(99, score))
    }

    private func warmthForReplyQueueScore(_ score: Int) -> AgenticSearchResult.Warmth {
        if score >= 80 { return .hot }
        if score >= 60 { return .warm }
        return .cold
    }

    private func pipelineCategoryString(_ category: FollowUpItem.Category) -> String {
        switch category {
        case .onMe:
            return "on_me"
        case .onThem:
            return "on_them"
        case .quiet:
            return "quiet"
        }
    }

    private func compactAIErrorReason(_ error: Swift.Error) -> String {
        let raw: String

        if let aiError = error as? AIError {
            switch aiError {
            case .httpError(let code, let body):
                let compactBody = body
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let suffix = compactBody.isEmpty ? "" : " \(String(compactBody.prefix(140)))"
                raw = "HTTP \(code)\(suffix)"
            case .parsingError(let detail):
                raw = "parse error \(String(detail.prefix(140)))"
            case .networkError(let err):
                raw = "network \(String(err.localizedDescription.prefix(120)))"
            case .noAPIKey:
                raw = "no API key configured"
            case .providerNotConfigured:
                raw = "provider not configured"
            case .invalidResponse:
                raw = "invalid provider response"
            }
        } else {
            let localized = error.localizedDescription
            if !localized.isEmpty {
                raw = localized
            } else {
                raw = String(describing: error)
            }
        }

        return raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func heuristicAgenticFallbackRanking(
        query: String,
        querySpec: QuerySpec,
        candidates: [AgenticSearchCandidate],
        myUserId: Int64,
        myUsername: String?
    ) -> [AgenticSearchResult] {
        let now = Date()
        let replyQueueQuery = isReplyQueueQuery(query: query, querySpec: querySpec)
        let stopWords: Set<String> = [
            "who", "what", "when", "where", "why", "how", "have", "has", "had",
            "with", "that", "this", "from", "your", "you", "for", "the", "and",
            "are", "was", "were", "can", "could", "would", "should", "about",
            "only", "last", "week", "month", "reply", "replied", "responded"
        ]
        let queryTokens = query
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 && !stopWords.contains($0) }

        return candidates.compactMap { candidate in
            guard chatMatchesScope(candidate.chat, scope: querySpec.scope) else { return nil }

            let rangedMessages = applyTimeRange(candidate.messages, timeRange: querySpec.timeRange)
            guard !rangedMessages.isEmpty else { return nil }

            let replyOwed = ConversationReplyHeuristics.isReplyOwed(
                for: candidate.chat,
                messages: rangedMessages,
                myUserId: myUserId
            )
            let strictReplySignal = candidate.strictReplySignal || ConversationReplyHeuristics.hasStrictReplyOpportunity(
                chat: candidate.chat,
                messages: rangedMessages,
                myUserId: myUserId,
                myUsername: myUsername
            )
            let effectiveGroupReplySignal = strictReplySignal || ConversationReplyHeuristics.hasLikelyDirectedGroupReplyOpportunity(
                chat: candidate.chat,
                messages: rangedMessages,
                myUserId: myUserId,
                myUsername: myUsername
            )

            if querySpec.replyConstraint == .pipelineOnMeOnly {
                if candidate.chat.chatType.isGroup, !effectiveGroupReplySignal {
                    return nil
                }
                if !strictReplySignal && !replyOwed && candidate.pipelineCategory != "on_me" {
                    return nil
                }
            }

            if replyQueueQuery, candidate.chat.chatType.isGroup, !effectiveGroupReplySignal {
                return nil
            }

            let newestFirst = rangedMessages.sorted { $0.date > $1.date }
            let inboundMessages = newestFirst.filter { message in
                if case .user(let senderId) = message.senderId {
                    return senderId != myUserId
                }
                return true
            }
            let outboundMessages = newestFirst.filter { message in
                if case .user(let senderId) = message.senderId {
                    return senderId == myUserId
                }
                return false
            }
            let latestInboundText = inboundMessages.first(where: { ($0.textContent?.isEmpty == false) })
            let latestOutboundText = outboundMessages.first(where: { ($0.textContent?.isEmpty == false) })

            let messageTexts = rangedMessages.compactMap(\.textContent)
            let corpus = ([candidate.chat.title.lowercased()] + messageTexts.map { $0.lowercased() })
                .joined(separator: " ")
            let matchedTokens = replyQueueQuery ? [] : queryTokens.filter { corpus.contains($0) }
            let tokenHits = matchedTokens.count

            var score = replyQueueQuery ? 18 : 24
            if replyOwed { score += replyQueueQuery ? 18 : 20 }
            if effectiveGroupReplySignal { score += replyQueueQuery ? 24 : 10 }
            if candidate.chat.unreadCount > 0 { score += 4 }
            switch candidate.pipelineCategory {
            case "on_me":
                score += replyQueueQuery ? 12 : 9
            case "on_them":
                score += 3
            default:
                break
            }
            if !replyQueueQuery {
                score += min(18, tokenHits * 6)
            }

            if candidate.chat.chatType.isPrivate {
                score += replyQueueQuery ? 14 : 4
            } else if replyQueueQuery {
                score -= 5
            }

            if let latestInboundDate = inboundMessages.map(\.date).max() {
                let age = now.timeIntervalSince(latestInboundDate)
                if age <= 86_400 {
                    score += 12
                } else if age <= 3 * 86_400 {
                    score += 8
                } else if age <= 7 * 86_400 {
                    score += 4
                }
            }

            let boundedScore = max(1, min(99, score))
            let warmth: AgenticSearchResult.Warmth
            if boundedScore >= 74 {
                warmth = .hot
            } else if boundedScore >= 54 {
                warmth = .warm
            } else {
                warmth = .cold
            }

            let replyability: AgenticSearchResult.Replyability
            if effectiveGroupReplySignal || (replyQueueQuery && replyOwed && candidate.chat.chatType.isPrivate) {
                replyability = .replyNow
            } else if latestOutboundText != nil {
                replyability = .waitingOnThem
            } else {
                replyability = .unclear
            }

            let inboundSender = latestInboundText?.senderName?
                .split(separator: " ")
                .first
                .map(String.init) ?? "them"
            let inboundSnippet = compactFallbackSnippet(latestInboundText?.textContent)
            let outboundSnippet = compactFallbackSnippet(latestOutboundText?.textContent)

            let suggestedAction: String
            switch replyability {
            case .replyNow:
                if !inboundSnippet.isEmpty {
                    suggestedAction = "Reply to \(inboundSender) on \"\(inboundSnippet)\" with a concrete next step."
                } else {
                    suggestedAction = "Send a quick reply and lock in the next step."
                }
            case .waitingOnThem:
                if !outboundSnippet.isEmpty, let latestOutboundText {
                    suggestedAction = "You already replied (\(latestOutboundText.relativeDate)); nudge only if \"\(outboundSnippet)\" is urgent."
                } else {
                    suggestedAction = "No immediate reply owed; keep this warm and nudge only if it is priority."
                }
            case .unclear:
                if tokenHits > 0 {
                    suggestedAction = "Re-open this thread with a short context check tied to your query."
                } else {
                    suggestedAction = "Review the latest context before deciding whether to engage."
                }
            }

            let reason: String
            if replyability == .replyNow, let latestInboundText {
                if replyQueueQuery {
                    reason = effectiveGroupReplySignal
                        ? "Recent inbound message looks like a direct open loop waiting on you."
                        : "Recent inbound message likely needs your reply."
                } else if tokenHits > 0 {
                    reason = "Inbound \(latestInboundText.relativeDate) ago and matched \(tokenHits) query term\(tokenHits == 1 ? "" : "s")."
                } else {
                    reason = "Inbound \(latestInboundText.relativeDate) ago suggests this thread is waiting on you."
                }
            } else if tokenHits > 0, let topToken = matchedTokens.first {
                reason = "Recent context matches \"\(topToken)\" but reply urgency is lower."
            } else if let latestOutboundText {
                reason = "Last outbound was \(latestOutboundText.relativeDate); waiting on their response."
            } else {
                reason = "Thread is relevant but currently lacks a clear open loop."
            }

            let tokenMatchedIds = newestFirst.compactMap { message -> Int64? in
                guard let text = message.textContent?.lowercased() else { return nil }
                return queryTokens.contains(where: { text.contains($0) }) ? message.id : nil
            }

            var supportingMessageIds: [Int64] = []
            if let inboundId = latestInboundText?.id {
                supportingMessageIds.append(inboundId)
            }
            if let outboundId = latestOutboundText?.id, !supportingMessageIds.contains(outboundId) {
                supportingMessageIds.append(outboundId)
            }
            for id in tokenMatchedIds where !supportingMessageIds.contains(id) {
                supportingMessageIds.append(id)
                if supportingMessageIds.count >= 2 { break }
            }
            if supportingMessageIds.isEmpty {
                supportingMessageIds = newestFirst.prefix(2).map(\.id)
            } else {
                supportingMessageIds = Array(supportingMessageIds.prefix(2))
            }

            let confidence = min(
                replyQueueQuery ? 0.82 : 0.74,
                0.46
                    + (replyOwed ? 0.10 : 0)
                    + (effectiveGroupReplySignal ? 0.12 : 0)
                    + min(0.12, Double(tokenHits) * 0.04)
            )

            return AgenticSearchResult(
                chatId: candidate.chat.id,
                chatTitle: candidate.chat.title,
                score: boundedScore,
                warmth: warmth,
                replyability: replyability,
                reason: reason,
                suggestedAction: suggestedAction,
                confidence: confidence,
                supportingMessageIds: supportingMessageIds
            )
        }
        .sorted { $0.score > $1.score }
    }

    private func compactFallbackSnippet(_ raw: String?, maxLength: Int = 70) -> String {
        guard let raw else { return "" }
        let cleaned = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }
        if cleaned.count <= maxLength { return cleaned }

        let index = cleaned.index(cleaned.startIndex, offsetBy: maxLength)
        let prefix = String(cleaned[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(prefix)…"
    }

    private func cachedFirstMessages(
        for chat: TGChat,
        desiredCount: Int,
        timeRange: TimeRangeConstraint?,
        telegramService: TelegramService
    ) async -> [TGMessage] {
        let cache = MessageCacheService.shared
        let step = AppConstants.AI.AgenticSearch.dateProbeStep
        let maxProbe = AppConstants.AI.AgenticSearch.maxDateProbeMessagesPerChat
        var deduped: [Int64: TGMessage] = [:]

        if let cached = await cache.getMessages(chatId: chat.id) {
            for message in cached {
                deduped[message.id] = message
            }
        }

        func textMessagesDescending() -> [TGMessage] {
            deduped.values
                .filter { ($0.textContent?.isEmpty == false) }
                .sorted { $0.date > $1.date }
        }

        func inRangeCount(from messages: [TGMessage]) -> Int {
            applyTimeRange(messages, timeRange: timeRange).count
        }

        var textMessages = textMessagesDescending()
        let requiresDateProbe = timeRange != nil

        if textMessages.count < desiredCount || (requiresDateProbe && inRangeCount(from: textMessages) < desiredCount) {
            let firstFetchLimit = requiresDateProbe ? max(desiredCount, step) : desiredCount
            if let fetched = try? await telegramService.getChatHistory(chatId: chat.id, limit: firstFetchLimit),
               !fetched.isEmpty {
                await cache.cacheMessages(chatId: chat.id, messages: fetched)
                for message in fetched {
                    deduped[message.id] = message
                }
                textMessages = textMessagesDescending()
            }
        }

        if let timeRange {
            while inRangeCount(from: textMessages) < desiredCount && textMessages.count < maxProbe {
                if let oldestDate = textMessages.last?.date, oldestDate <= timeRange.startDate {
                    break
                }

                let oldestKnownId = textMessages.last?.id ?? 0
                guard oldestKnownId != 0 else { break }

                let remaining = maxProbe - textMessages.count
                let fetchLimit = min(step, remaining)
                guard fetchLimit > 0 else { break }

                guard let older = try? await telegramService.getChatHistory(
                    chatId: chat.id,
                    fromMessageId: oldestKnownId,
                    limit: fetchLimit
                ), !older.isEmpty else {
                    break
                }

                let previousCount = textMessages.count
                await cache.cacheMessages(chatId: chat.id, messages: older, append: true)
                for message in older {
                    deduped[message.id] = message
                }
                textMessages = textMessagesDescending()
                if textMessages.count <= previousCount {
                    break
                }
            }
        }

        let filtered = applyTimeRange(textMessages, timeRange: timeRange)
        return Array(filtered.prefix(desiredCount))
    }

    private func topUpOlderMessages(
        for chat: TGChat,
        existingMessages: [TGMessage],
        additionalCount: Int,
        maxTotal: Int,
        timeRange: TimeRangeConstraint?,
        telegramService: TelegramService
    ) async -> [TGMessage] {
        var deduped: [Int64: TGMessage] = [:]
        for message in existingMessages {
            deduped[message.id] = message
        }

        let currentCount = deduped.values.filter { ($0.textContent?.isEmpty == false) }.count
        guard currentCount < maxTotal else {
            let messages = deduped.values
                .filter { ($0.textContent?.isEmpty == false) }
                .sorted { $0.date > $1.date }
                .prefix(maxTotal)
                .map { $0 }
            return applyTimeRange(messages, timeRange: timeRange)
        }

        let toFetch = min(additionalCount, maxTotal - currentCount)
        guard toFetch > 0 else {
            let messages = deduped.values
                .filter { ($0.textContent?.isEmpty == false) }
                .sorted { $0.date > $1.date }
                .prefix(maxTotal)
                .map { $0 }
            return applyTimeRange(messages, timeRange: timeRange)
        }

        let oldestKnownId = deduped.values.sorted { $0.date > $1.date }.last?.id ?? 0
        guard oldestKnownId != 0 else {
            let messages = deduped.values
                .filter { ($0.textContent?.isEmpty == false) }
                .sorted { $0.date > $1.date }
                .prefix(maxTotal)
                .map { $0 }
            return applyTimeRange(messages, timeRange: timeRange)
        }

        if let older = try? await telegramService.getChatHistory(
            chatId: chat.id,
            fromMessageId: oldestKnownId,
            limit: toFetch
        ), !older.isEmpty {
            await MessageCacheService.shared.cacheMessages(chatId: chat.id, messages: older, append: true)
            for message in older {
                deduped[message.id] = message
            }
        }

        let messages = deduped.values
            .filter { ($0.textContent?.isEmpty == false) }
            .sorted { $0.date > $1.date }
            .prefix(maxTotal)
            .map { $0 }
        return applyTimeRange(messages, timeRange: timeRange)
    }
}
