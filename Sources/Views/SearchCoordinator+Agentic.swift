import Foundation

struct AgenticDebugInfo {
    var scopedChats: Int
    var maxScanChats: Int
    var providerName: String = ""
    var providerModel: String = ""
    var scannedChats: Int = 0
    var inRangeChats: Int = 0
    var replyOwedChats: Int = 0
    var matchedChats: Int = 0
    var candidatesSentToAI: Int = 0
    var aiReturned: Int = 0
    var rankedBeforeValidation: Int = 0
    var droppedByValidation: Int = 0
    var finalCount: Int = 0
    var stopReason: String = "unknown"
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
        let rawScopedChats = await collectAgenticCandidateChats(
            scope: resolvedQuerySpec.scope,
            aiSearchSourceChats: aiSearchSourceChats,
            includeBotsInAISearch: includeBotsInAISearch,
            telegramService: telegramService
        )
        let allChats = prioritizeAgenticChats(
            rawScopedChats,
            query: query,
            pipelineCategoryProvider: pipelineCategoryProvider
        )
        let maxScanChats = min(allChats.count, constants.maxAdaptiveScanChats)
        var debug = AgenticDebugInfo(
            scopedChats: allChats.count,
            maxScanChats: maxScanChats,
            providerName: aiService.providerType.rawValue,
            providerModel: aiService.providerModel
        )
        guard !allChats.isEmpty else {
            debug.stopReason = "no chats after scope/type prefilters"
            agenticDebugInfo = debug
            return []
        }

        let chatById = Dictionary(uniqueKeysWithValues: allChats.map { ($0.id, $0) })
        let myUserId = telegramService.currentUser?.id ?? 0

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
                let rawMessages = await cachedFirstMessages(
                    for: chat,
                    desiredCount: constants.initialMessagesPerChat,
                    timeRange: resolvedQuerySpec.timeRange,
                    telegramService: telegramService
                )
                let messages = applyTimeRange(rawMessages, timeRange: resolvedQuerySpec.timeRange)
                guard !messages.isEmpty else { continue }
                debug.inRangeChats += 1

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
                if replyOwed {
                    debug.replyOwedChats += 1
                }

                guard chatLikelyMatchesAgenticQuery(
                    chat: chat,
                    messages: messages,
                    query: query,
                    pipelineHint: effectivePipelineCategory,
                    replyOwed: replyOwed,
                    querySpec: resolvedQuerySpec
                ) else { continue }
                debug.matchedChats += 1

                candidateByChatId[chat.id] = AgenticSearchCandidate(
                    chat: chat,
                    pipelineCategory: replyOwed ? "on_me" : effectivePipelineCategory,
                    messages: messages
                )
            }

            semanticMatchedChats = scanOffset

            let candidates = allChats
                .compactMap { candidateByChatId[$0.id] }
                .prefix(constants.maxCandidateChats)
                .map { $0 }
            debug.candidatesSentToAI = max(debug.candidatesSentToAI, candidates.count)

            if candidates.isEmpty {
                round += 1
                continue
            }

            let ranked: [AgenticSearchResult]
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
                debug.stopReason = reason.isEmpty
                    ? "agentic provider call failed"
                    : "agentic provider call failed: \(reason)"

                let fallbackRanked = heuristicAgenticFallbackRanking(
                    query: query,
                    querySpec: resolvedQuerySpec,
                    candidates: candidates,
                    myUserId: myUserId
                )
                latestRanked = fallbackRanked
                debug.aiReturned = max(debug.aiReturned, fallbackRanked.count)
                if !fallbackRanked.isEmpty {
                    debug.stopReason += " • using local fallback"
                }
                break
            }

            latestRanked = ranked
            debug.aiReturned = max(debug.aiReturned, ranked.count)
            let topIds = Array(ranked.prefix(5).map(\.chatId))
            let topCount = min(5, ranked.count)
            let avgTopConfidence: Double
            if topCount > 0 {
                avgTopConfidence = ranked.prefix(topCount).map(\.confidence).reduce(0, +) / Double(topCount)
            } else {
                avgTopConfidence = 0
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
            if confidenceGood || stableRounds >= 1 || (foundEnoughCandidates && round > 0) {
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
            agenticDebugInfo = debug
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
                    pipelineCategory: replyOwed ? "on_me" : effectivePipelineCategory,
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
                satisfiesHardConstraints(
                    result: result,
                    candidateByChatId: candidateByChatId,
                    querySpec: resolvedQuerySpec
                )
            }
        debug.droppedByValidation = max(0, rankedBeforeValidation.count - validatedRanked.count)

        let finalRanked = validatedRanked
            .prefix(constants.maxCandidateChats)
            .map { $0 }
        debug.finalCount = finalRanked.count

        if finalRanked.isEmpty {
            if debug.rankedBeforeValidation > 0 {
                debug.stopReason = "all ranked results failed hard constraints"
            } else {
                debug.stopReason = "no ranked results before validation"
            }
            agenticDebugInfo = debug
            return []
        }

        debug.stopReason = "ok"
        agenticDebugInfo = debug
        return finalRanked.map { .agenticResult($0) }
    }

    private func prioritizeAgenticChats(
        _ chats: [TGChat],
        query: String,
        pipelineCategoryProvider: (Int64) -> FollowUpItem.Category?
    ) -> [TGChat] {
        let normalizedQuery = query.lowercased()
        let tokens = normalizedQuery
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 }
        let now = Date()

        return chats.sorted { a, b in
            func score(_ chat: TGChat) -> Int {
                let title = chat.title.lowercased()
                let preview = chat.lastMessage?.displayText.lowercased() ?? ""
                var total = 0

                if title.contains(normalizedQuery) { total += 30 }
                for token in tokens {
                    if title.contains(token) { total += 8 }
                    if preview.contains(token) { total += 5 }
                }

                if let status = pipelineCategoryProvider(chat.id) {
                    switch status {
                    case .onMe: total += 12
                    case .onThem: total += 4
                    case .quiet: break
                    }
                }

                if chat.unreadCount > 0 { total += 6 }

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
    }

    private func chatLikelyMatchesAgenticQuery(
        chat: TGChat,
        messages: [TGMessage],
        query: String,
        pipelineHint: String,
        replyOwed: Bool,
        querySpec: QuerySpec
    ) -> Bool {
        if querySpec.replyConstraint == .pipelineOnMeOnly && pipelineHint == "on_me" {
            return true
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
            return true
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
            if pipelineHint == "on_me" {
                return true
            }
            if replyOwed { return true }
        }

        if normalizedQuery.contains("intro") || normalizedQuery.contains("connect") {
            if corpus.contains("intro") || corpus.contains("connect") {
                return true
            }
        }

        return false
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

    private func satisfiesHardConstraints(
        result: AgenticSearchResult,
        candidateByChatId: [Int64: AgenticSearchCandidate],
        querySpec: QuerySpec
    ) -> Bool {
        guard let candidate = candidateByChatId[result.chatId] else { return false }

        if !chatMatchesScope(candidate.chat, scope: querySpec.scope) {
            return false
        }

        if querySpec.replyConstraint == .pipelineOnMeOnly {
            let satisfiesPipeline = candidate.pipelineCategory == "on_me"
            let satisfiesReplySignal = result.replyability == .replyNow
            if !satisfiesPipeline && !satisfiesReplySignal {
                return false
            }
        }

        if let timeRange = querySpec.timeRange,
           !candidate.messages.contains(where: { timeRange.contains($0.date) }) {
            return false
        }

        return true
    }

    private func collectAgenticCandidateChats(
        scope: QueryScope,
        aiSearchSourceChats: [TGChat],
        includeBotsInAISearch: Bool,
        telegramService: TelegramService
    ) async -> [TGChat] {
        let now = Date()
        let maxAge = AppConstants.FollowUp.maxPipelineAgeSeconds

        let scoped = aiSearchSourceChats.filter { chat in
            guard let lastMessage = chat.lastMessage else { return false }
            guard !chat.chatType.isChannel else { return false }
            switch scope {
            case .all:
                guard chat.chatType.isPrivate || chat.chatType.isGroup else { return false }
            case .dms:
                guard chat.chatType.isPrivate else { return false }
            case .groups:
                guard chat.chatType.isGroup else { return false }
            }

            let age = now.timeIntervalSince(lastMessage.date)
            guard age <= maxAge else { return false }

            if chat.chatType.isGroup {
                if let count = chat.memberCount, count > AppConstants.FollowUp.maxGroupMembers { return false }
                if chat.unreadCount > AppConstants.FollowUp.maxGroupUnread { return false }
            }
            return true
        }

        guard !includeBotsInAISearch else { return scoped }

        var filtered: [TGChat] = []
        filtered.reserveCapacity(scoped.count)
        for chat in scoped {
            if await telegramService.isBotChat(chat) {
                continue
            }
            filtered.append(chat)
        }
        return filtered
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
        myUserId: Int64
    ) -> [AgenticSearchResult] {
        let now = Date()
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
            if querySpec.replyConstraint == .pipelineOnMeOnly,
               !replyOwed,
               candidate.pipelineCategory != "on_me" {
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
            let matchedTokens = queryTokens.filter { corpus.contains($0) }
            let tokenHits = matchedTokens.count

            var score = 24
            if replyOwed { score += 20 }
            if candidate.chat.unreadCount > 0 { score += 4 }
            switch candidate.pipelineCategory {
            case "on_me":
                score += 9
            case "on_them":
                score += 3
            default:
                break
            }
            score += min(18, tokenHits * 6)

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
            if replyOwed {
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
                if tokenHits > 0 {
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
                0.74,
                0.46 + (replyOwed ? 0.10 : 0) + min(0.12, Double(tokenHits) * 0.04)
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
