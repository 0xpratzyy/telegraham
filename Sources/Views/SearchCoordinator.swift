import Foundation
import Combine
import TDLibKit

enum AISearchResult: Identifiable {
    case semanticResult(SemanticSearchResult)
    case agenticResult(AgenticSearchResult)
    case patternResult(PatternSearchResult)
    case replyQueueResult(ReplyQueueResult)

    var id: String {
        switch self {
        case .semanticResult(let result): return "sem-\(result.id)"
        case .agenticResult(let result): return "ag-\(result.id)"
        case .patternResult(let result): return "pattern-\(result.id)"
        case .replyQueueResult(let result): return "reply-\(result.id)"
        }
    }

    func linkedChat(in chats: [TGChat]) -> TGChat? {
        switch self {
        case .semanticResult(let result):
            return chats.first(where: { $0.id == result.chatId })
        case .agenticResult(let result):
            return chats.first(where: { $0.id == result.chatId })
        case .patternResult(let result):
            if let chat = result.chat { return chat }
            return chats.first(where: { $0.id == result.message.chatId })
        case .replyQueueResult(let result):
            return chats.first(where: { $0.id == result.chatId })
        }
    }
}

private struct LocalSemanticMessageScore {
    let message: TGMessage
    var ftsScore: Double
    var vectorScore: Double
}

private struct LocalSemanticChatCandidate {
    let chat: TGChat
    var bestMessage: TGMessage?
    var bestSnippet: String
    var sortDate: Foundation.Date
    var ftsScore: Double
    var vectorScore: Double
    var titleScore: Double
    var fallbackScore: Double
}

@MainActor
final class SearchCoordinator: ObservableObject {
    @Published var searchResultChatIds: Set<Int64> = []
    @Published var isSearching = false
    @Published var aiResults: [AISearchResult] = []
    @Published var aiSearchMode: QueryIntent? = nil
    @Published var routedQueryIntent: QueryIntent? = nil
    @Published var routingSnapshot: SearchRoutingSnapshot?
    @Published var isAISearching = false
    @Published var aiSearchError: String?
    @Published var currentQuerySpec: QuerySpec?
    @Published var agenticDebugInfo: AgenticDebugInfo?
    @Published var summaryOutput: SummarySearchOutput?
    @Published var semanticMatchedChats: Int = 0
    @Published var totalChatsToScan: Int = 0
    @Published var searchStartedAt: Foundation.Date?
    @Published var lastSearchDuration: TimeInterval?

    private var searchTask: Task<Void, Never>?
    var activeSearchRunID = UUID()
    let queryInterpreter: QueryInterpreting

    init(queryInterpreter: QueryInterpreting = QueryInterpreter()) {
        self.queryInterpreter = queryInterpreter
    }

    deinit {
        searchTask?.cancel()
    }

    func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
    }

    func clearAllState() {
        cancelSearch()
        searchResultChatIds = []
        isSearching = false
        clearAIState()
    }

    func clearAIState() {
        aiResults = []
        aiSearchMode = nil
        routedQueryIntent = nil
        routingSnapshot = nil
        isAISearching = false
        aiSearchError = nil
        currentQuerySpec = nil
        agenticDebugInfo = nil
        summaryOutput = nil
        semanticMatchedChats = 0
        totalChatsToScan = 0
        searchStartedAt = nil
        lastSearchDuration = nil
    }

    func triggerSearch(
        query rawQuery: String,
        activeScope: QueryScope,
        visibleChats: [TGChat],
        aiSearchSourceChats: [TGChat],
        scopedAISearchSourceChats: [TGChat],
        includeBotsInAISearch: Bool,
        telegramService: TelegramService,
        aiService: AIService,
        pipelineCategoryProvider: @escaping (Int64) -> FollowUpItem.Category?,
        pipelineHintProvider: @escaping (Int64) async -> String
    ) {
        cancelSearch()

        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if let matchingChat = aiSearchSourceChats.first(where: { $0.title.localizedCaseInsensitiveContains(query) }) {
            Task {
                await IndexScheduler.shared.prioritize(chatId: matchingChat.id)
            }
        }

        guard query.count >= 2 else {
            clearAllState()
            return
        }

        let parsedSpec = queryInterpreter.parse(
            query: query,
            now: Date(),
            timezone: .current,
            activeFilter: activeScope
        )

        currentQuerySpec = parsedSpec
        let searchRunID = UUID()
        activeSearchRunID = searchRunID
        routedQueryIntent = nil
        routingSnapshot = nil
        aiSearchMode = nil
        aiResults = []
        aiSearchError = nil
        agenticDebugInfo = nil
        summaryOutput = nil
        semanticMatchedChats = 0
        totalChatsToScan = 0
        searchStartedAt = nil
        lastSearchDuration = nil
        searchResultChatIds = []
        isSearching = false
        isAISearching = false

        searchTask = Task { @MainActor in
            let intent = await aiService.queryRouter.route(
                query: query,
                querySpec: parsedSpec,
                activeFilter: activeScope,
                timezone: .current,
                now: Date()
            )
            guard !Task.isCancelled else { return }

            routedQueryIntent = intent
            routingSnapshot = SearchRoutingSnapshot(
                query: query,
                spec: parsedSpec,
                runtimeIntent: intent
            )

            if intent == .unsupported || parsedSpec.preferredEngine == .graphCRM {
                aiSearchMode = nil
                aiResults = []
                summaryOutput = nil
                aiSearchError = "Relationship / CRM queries are recognized, but the dedicated engine is not part of the MVP yet."
                isAISearching = false
                return
            }

            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }

            searchStartedAt = Foundation.Date()
            lastSearchDuration = nil
            aiSearchMode = intent
            isAISearching = true
            aiSearchError = nil
            currentQuerySpec = parsedSpec
            summaryOutput = nil
            searchResultChatIds = []

            do {
                let results = try await executeAISearch(
                    intent: intent,
                    query: query,
                    querySpec: parsedSpec,
                    searchRunID: searchRunID,
                    activeScope: activeScope,
                    aiSearchSourceChats: aiSearchSourceChats,
                    scopedAISearchSourceChats: scopedAISearchSourceChats,
                    includeBotsInAISearch: includeBotsInAISearch,
                    telegramService: telegramService,
                    aiService: aiService,
                    pipelineCategoryProvider: pipelineCategoryProvider,
                    pipelineHintProvider: pipelineHintProvider
                )
                guard !Task.isCancelled else { return }
                aiResults = results
                isAISearching = false
                markSearchFinished()
            } catch {
                guard !Task.isCancelled else { return }
                aiSearchError = error.localizedDescription
                isAISearching = false
                markSearchFinished()
            }
        }
    }

    private func markSearchFinished() {
        if let startedAt = searchStartedAt {
            lastSearchDuration = max(0, Foundation.Date().timeIntervalSince(startedAt))
        }
        searchStartedAt = nil
    }

    private func executeAISearch(
        intent: QueryIntent,
        query: String,
        querySpec: QuerySpec?,
        searchRunID: UUID,
        activeScope: QueryScope,
        aiSearchSourceChats: [TGChat],
        scopedAISearchSourceChats: [TGChat],
        includeBotsInAISearch: Bool,
        telegramService: TelegramService,
        aiService: AIService,
        pipelineCategoryProvider: @escaping (Int64) -> FollowUpItem.Category?,
        pipelineHintProvider: @escaping (Int64) async -> String
    ) async throws -> [AISearchResult] {
        let resolvedQuerySpec = querySpec ?? queryInterpreter.parse(
            query: query,
            now: Date(),
            timezone: .current,
            activeFilter: activeScope
        )
        let resolvedScope = resolvedQuerySpec.scope
        let resolvedScopedChats: [TGChat]
        if resolvedScope == activeScope {
            resolvedScopedChats = scopedAISearchSourceChats
        } else {
            resolvedScopedChats = scopedChats(from: aiSearchSourceChats, scope: resolvedScope)
        }

        switch resolvedQuerySpec.preferredEngine {
        case .messageLookup:
            return await executePatternSearch(
                querySpec: resolvedQuerySpec,
                scope: resolvedScope,
                scopedChats: resolvedScopedChats,
                telegramService: telegramService
            )
        case .semanticRetrieval:
            return await executeLocalSemanticSearch(
                query: query,
                scope: resolvedScope,
                scopedChats: resolvedScopedChats,
                telegramService: telegramService,
                aiService: aiService
            )
        case .replyTriage:
            return try await executeAgenticSearch(
                query: query,
                querySpec: resolvedQuerySpec,
                searchRunID: searchRunID,
                activeScope: activeScope,
                aiSearchSourceChats: aiSearchSourceChats,
                includeBotsInAISearch: includeBotsInAISearch,
                telegramService: telegramService,
                aiService: aiService,
                pipelineCategoryProvider: pipelineCategoryProvider,
                pipelineHintProvider: pipelineHintProvider
            )
        case .summarize:
            return await executeSummarySearch(
                querySpec: resolvedQuerySpec,
                scope: resolvedScope,
                scopedChats: resolvedScopedChats,
                telegramService: telegramService,
                aiService: aiService
            )
        case .graphCRM:
            return []
        }
    }

    private func executePatternSearch(
        querySpec: QuerySpec,
        scope: QueryScope,
        scopedChats: [TGChat],
        telegramService: TelegramService
    ) async -> [AISearchResult] {
        let results = await PatternSearchEngine.shared.search(
            query: querySpec,
            scope: scope,
            scopedChats: scopedChats,
            telegramService: telegramService
        )
        totalChatsToScan = 0
        semanticMatchedChats = 0
        return results.map { .patternResult($0) }
    }

    private func executeSummarySearch(
        querySpec: QuerySpec,
        scope: QueryScope,
        scopedChats: [TGChat],
        telegramService: TelegramService,
        aiService: AIService
    ) async -> [AISearchResult] {
        let execution = await SummaryEngine.shared.search(
            query: querySpec,
            scope: scope,
            scopedChats: scopedChats,
            telegramService: telegramService,
            aiService: aiService
        )
        summaryOutput = execution.output
        totalChatsToScan = execution.results.count
        semanticMatchedChats = execution.results.count
        return execution.results.map { .semanticResult($0) }
    }

    private func executeLocalSemanticSearch(
        query: String,
        scope: QueryScope,
        scopedChats: [TGChat],
        telegramService: TelegramService,
        aiService: AIService
    ) async -> [AISearchResult] {
        let constants = AppConstants.AI.SemanticSearch.self
        semanticMatchedChats = 0
        totalChatsToScan = 0

        guard !scopedChats.isEmpty else {
            return []
        }

        let scopedChatIds = scopedChats.map(\.id)
        let chatById = Dictionary(uniqueKeysWithValues: scopedChats.map { ($0.id, $0) })

        let ftsHits = await telegramService.localScoredSearch(
            query: query,
            chatIds: scopedChatIds,
            limit: constants.ftsTopMessages
        )
        let vectorHits = await telegramService.localVectorSearch(
            query: query,
            chatIds: scopedChatIds,
            limit: constants.vectorTopMessages
        )

        let mergedHits = mergeLocalSemanticHits(ftsHits: ftsHits, vectorHits: vectorHits)
        var candidatesByChatId = buildLocalSemanticCandidates(from: mergedHits, chatsById: chatById)
        mergeTitleSemanticCandidates(
            query: query,
            chats: scopedChats,
            candidatesByChatId: &candidatesByChatId
        )

        let candidates = Array(candidatesByChatId.values).sorted { (lhs: LocalSemanticChatCandidate, rhs: LocalSemanticChatCandidate) in
            let leftScore = semanticCandidateScore(lhs)
            let rightScore = semanticCandidateScore(rhs)
            if leftScore != rightScore {
                return leftScore > rightScore
            }
            if lhs.sortDate != rhs.sortDate {
                return lhs.sortDate > rhs.sortDate
            }
            return lhs.chat.id < rhs.chat.id
        }

        totalChatsToScan = candidates.count
        semanticMatchedChats = candidates.count

        guard !candidates.isEmpty else { return [] }

        let rankedCandidates: [LocalSemanticChatCandidate]
        if aiService.isConfigured {
            do {
                rankedCandidates = try await rerankSemanticCandidates(
                    query: query,
                    candidates: candidates,
                    aiService: aiService
                )
            } catch {
                rankedCandidates = candidates
            }
        } else {
            rankedCandidates = candidates
        }

        return rankedCandidates
            .prefix(constants.maxRenderedSemanticResults)
            .enumerated()
            .map { index, candidate in
                let result = SemanticSearchResult(
                    chatId: candidate.chat.id,
                    chatTitle: candidate.chat.title,
                    reason: semanticReason(for: candidate),
                    relevance: semanticRelevance(for: candidate, rank: index),
                    matchingMessages: [candidate.bestSnippet]
                )
                return .semanticResult(result)
            }
    }

    private func mergeLocalSemanticHits(
        ftsHits: [TelegramService.LocalMessageSearchHit],
        vectorHits: [TelegramService.LocalMessageSearchHit]
    ) -> [LocalSemanticMessageScore] {
        let maxFTSScore = ftsHits.map(\.score).max() ?? 0
        let maxVectorScore = vectorHits.map { max(0, $0.score) }.max() ?? 0

        var merged: [String: LocalSemanticMessageScore] = [:]

        for hit in ftsHits {
            let key = "\(hit.message.chatId):\(hit.message.id)"
            let normalizedScore = normalizeLocalSemanticScore(hit.score, maxScore: maxFTSScore)
            if var existing = merged[key] {
                existing.ftsScore = max(existing.ftsScore, normalizedScore)
                merged[key] = existing
            } else {
                merged[key] = LocalSemanticMessageScore(
                    message: hit.message,
                    ftsScore: normalizedScore,
                    vectorScore: 0
                )
            }
        }

        for hit in vectorHits {
            let key = "\(hit.message.chatId):\(hit.message.id)"
            let normalizedScore = normalizeLocalSemanticScore(max(0, hit.score), maxScore: maxVectorScore)
            if var existing = merged[key] {
                existing.vectorScore = max(existing.vectorScore, normalizedScore)
                merged[key] = existing
            } else {
                merged[key] = LocalSemanticMessageScore(
                    message: hit.message,
                    ftsScore: 0,
                    vectorScore: normalizedScore
                )
            }
        }

        return merged.values.sorted { lhs, rhs in
            let leftScore = semanticMessageScore(lhs)
            let rightScore = semanticMessageScore(rhs)
            if leftScore != rightScore {
                return leftScore > rightScore
            }
            if lhs.message.date != rhs.message.date {
                return lhs.message.date > rhs.message.date
            }
            return lhs.message.id > rhs.message.id
        }
    }

    private func buildLocalSemanticCandidates(
        from mergedHits: [LocalSemanticMessageScore],
        chatsById: [Int64: TGChat]
    ) -> [Int64: LocalSemanticChatCandidate] {
        var bestByChatId: [Int64: LocalSemanticChatCandidate] = [:]

        for hit in mergedHits {
            guard let chat = chatsById[hit.message.chatId] else { continue }
            let snippet = semanticSnippet(from: hit.message.textContent ?? hit.message.displayText)

            let candidate = LocalSemanticChatCandidate(
                chat: chat,
                bestMessage: hit.message,
                bestSnippet: snippet,
                sortDate: hit.message.date,
                ftsScore: hit.ftsScore,
                vectorScore: hit.vectorScore,
                titleScore: 0,
                fallbackScore: 0
            )

            if let existing = bestByChatId[chat.id] {
                bestByChatId[chat.id] = betterSemanticCandidate(existing, candidate)
            } else {
                bestByChatId[chat.id] = candidate
            }
        }

        return bestByChatId
    }

    private func mergeTitleSemanticCandidates(
        query: String,
        chats: [TGChat],
        candidatesByChatId: inout [Int64: LocalSemanticChatCandidate]
    ) {
        for chat in chats {
            let titleScore = normalizedTitleMatchScore(query: query, title: chat.title)
            guard titleScore > 0 else { continue }

            let normalizedQuery = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedTitle = chat.title.lowercased()
            let latestTitleContext = semanticSnippet(from: chat.lastMessage?.textContent ?? chat.lastMessage?.displayText ?? "")
            let titleSnippet: String
            if normalizedTitle == normalizedQuery {
                titleSnippet = latestTitleContext.isEmpty
                    ? "Exact chat title match"
                    : latestTitleContext
            } else if !latestTitleContext.isEmpty && latestTitleContext.lowercased().contains(normalizedQuery) {
                titleSnippet = latestTitleContext
            } else {
                titleSnippet = "Chat title contains \"\(query)\""
            }

            let titleCandidate = LocalSemanticChatCandidate(
                chat: chat,
                bestMessage: chat.lastMessage,
                bestSnippet: titleSnippet,
                sortDate: chat.lastMessage?.date ?? .distantPast,
                ftsScore: 0,
                vectorScore: 0,
                titleScore: titleScore,
                fallbackScore: 0
            )

            if let existing = candidatesByChatId[chat.id] {
                var merged = existing
                merged.titleScore = max(existing.titleScore, titleScore)
                if semanticCandidateScore(titleCandidate) > semanticCandidateScore(existing) && existing.ftsScore == 0 && existing.vectorScore == 0 {
                    merged.bestSnippet = titleCandidate.bestSnippet
                }
                if titleCandidate.sortDate > merged.sortDate {
                    merged.sortDate = titleCandidate.sortDate
                    if merged.bestMessage == nil {
                        merged.bestMessage = titleCandidate.bestMessage
                    }
                }
                candidatesByChatId[chat.id] = merged
            } else {
                candidatesByChatId[chat.id] = titleCandidate
            }
        }
    }

    private func betterSemanticCandidate(
        _ existing: LocalSemanticChatCandidate,
        _ incoming: LocalSemanticChatCandidate
    ) -> LocalSemanticChatCandidate {
        let existingScore = semanticCandidateScore(existing)
        let incomingScore = semanticCandidateScore(incoming)

        if incomingScore > existingScore {
            return incoming
        }

        if incomingScore == existingScore && incoming.sortDate > existing.sortDate {
            return incoming
        }

        return existing
    }

    private func semanticMessageScore(_ hit: LocalSemanticMessageScore) -> Double {
        (hit.ftsScore * AppConstants.AI.SemanticSearch.ftsWeight)
        + (hit.vectorScore * AppConstants.AI.SemanticSearch.vectorWeight)
    }

    private func semanticCandidateScore(_ candidate: LocalSemanticChatCandidate) -> Double {
        let hasHistorySignal = candidate.ftsScore > 0 || candidate.vectorScore > 0 || candidate.fallbackScore > 0
        let isExactTitleMatch = candidate.titleScore >= 0.99

        var score =
            (candidate.ftsScore * AppConstants.AI.SemanticSearch.ftsWeight) +
            (candidate.vectorScore * AppConstants.AI.SemanticSearch.vectorWeight) +
            (candidate.titleScore * AppConstants.AI.SemanticSearch.titleWeight) +
            (candidate.fallbackScore * AppConstants.AI.SemanticSearch.fallbackWeight)

        if candidate.titleScore > 0 {
            if isExactTitleMatch {
                score += AppConstants.AI.SemanticSearch.exactTitleBoost
            }
            if hasHistorySignal {
                score += AppConstants.AI.SemanticSearch.titleHistoryBonus
            } else {
                score -= AppConstants.AI.SemanticSearch.titleOnlyPenalty
            }
        }

        if candidate.chat.chatType.isPrivate {
            score += AppConstants.AI.SemanticSearch.dmBonus
        } else if candidate.chat.chatType.isGroup {
            if let memberCount = candidate.chat.memberCount, memberCount <= 8 {
                score += AppConstants.AI.SemanticSearch.smallGroupBonus
            } else if let memberCount = candidate.chat.memberCount, memberCount > 50 {
                score -= AppConstants.AI.SemanticSearch.largeGroupPenalty
            }
        }

        return score
    }

    private func normalizedTitleMatchScore(query: String, title: String) -> Double {
        let normalizedQuery = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTitle = title.lowercased()
        guard !normalizedQuery.isEmpty, !normalizedTitle.isEmpty else { return 0 }

        if normalizedTitle == normalizedQuery {
            return 1
        }

        if normalizedTitle.contains(normalizedQuery) {
            return 0.55
        }

        let tokens = normalizedQuery
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 2 }
        guard !tokens.isEmpty else { return 0 }

        let matched = tokens.filter { normalizedTitle.contains($0) }
        guard !matched.isEmpty else { return 0 }

        return min(0.85, max(0.2, Double(matched.count) / Double(tokens.count)))
    }

    private func rerankSemanticCandidates(
        query: String,
        candidates: [LocalSemanticChatCandidate],
        aiService: AIService
    ) async throws -> [LocalSemanticChatCandidate] {
        let maxRerank = AppConstants.AI.SemanticSearch.maxLocalChatsForRerank
        let topCandidates = Array(candidates.prefix(maxRerank))
        let rerankedIds = try await aiService.rerankSearchResults(
            query: query,
            candidates: topCandidates.map { candidate in
                (
                    chatId: candidate.chat.id,
                    chatTitle: candidate.chat.title,
                    bestMessage: candidate.bestSnippet
                )
            }
        )

        guard !rerankedIds.isEmpty else { return candidates }

        let topById = Dictionary(uniqueKeysWithValues: topCandidates.map { ($0.chat.id, $0) })
        let orderedTop = rerankedIds.compactMap { topById[$0] }
        let orderedIdSet = Set(orderedTop.map(\.chat.id))
        let remainingTop = topCandidates.filter { !orderedIdSet.contains($0.chat.id) }
        let tailCandidates = Array(candidates.dropFirst(topCandidates.count))

        return orderedTop + remainingTop + tailCandidates
    }

    private func normalizeLocalSemanticScore(_ score: Double, maxScore: Double) -> Double {
        guard maxScore > 0 else { return 0 }
        return min(1, max(0, score / maxScore))
    }

    private func semanticSnippet(from text: String) -> String {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        let truncated = normalized.prefix(AppConstants.AI.SemanticSearch.messagePreviewCharacterLimit)
        return String(truncated)
    }

    private func semanticReason(for candidate: LocalSemanticChatCandidate) -> String {
        if candidate.titleScore > 0 && candidate.ftsScore == 0 && candidate.vectorScore == 0 && candidate.fallbackScore == 0 {
            return candidate.titleScore >= 0.99 ? "Exact chat title match" : "Chat title matched the query"
        }
        if candidate.fallbackScore > 0 && candidate.ftsScore == 0 && candidate.vectorScore == 0 {
            return "Matched in live Telegram search for an unindexed chat"
        }
        if candidate.titleScore > 0 && (candidate.ftsScore > 0 || candidate.vectorScore > 0) {
            return "Matched title and local history"
        }
        if candidate.ftsScore > 0 && candidate.vectorScore > 0 {
            return "Matched both keywords and semantic context"
        }
        if candidate.ftsScore > 0 {
            return "Strong keyword match in local history"
        }
        if candidate.vectorScore > 0 {
            return "Strong semantic match in local history"
        }
        return "Strong semantic match in local history"
    }

    private func semanticRelevance(
        for candidate: LocalSemanticChatCandidate,
        rank: Int
    ) -> SemanticSearchResult.Relevance {
        let score = semanticCandidateScore(candidate)
        let isTitleOnly = candidate.titleScore > 0
            && candidate.ftsScore == 0
            && candidate.vectorScore == 0
            && candidate.fallbackScore == 0

        if isTitleOnly && candidate.titleScore < 0.99 {
            return .medium
        }
        if score >= AppConstants.AI.SemanticSearch.highRelevanceThreshold {
            return .high
        }
        if rank < 3 && score >= AppConstants.AI.SemanticSearch.mediumRelevanceThreshold {
            return .high
        }
        return .medium
    }

    private func scopedChats(from visibleChats: [TGChat], scope: QueryScope) -> [TGChat] {
        switch scope {
        case .all:
            return visibleChats
        case .dms:
            return visibleChats.filter { $0.chatType.isPrivate }
        case .groups:
            return visibleChats.filter { $0.chatType.isGroup }
        }
    }

}
