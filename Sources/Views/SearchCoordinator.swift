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
    var queryCoverage: Int
    var phraseCoverage: Int
    var anchorCoverage: Int
    var bestQueryMatches: Int
    var bestPhraseMatches: Int
    var bestAnchorMatches: Int
    var matchedMessageCount: Int
}

private struct SemanticTopicQueryContext {
    let query: String
    let focusQuery: String
    let queryTokens: [String]
    let phraseCandidates: [String]
    let anchorTokens: [String]

    var requiresGuardedTopicRanking: Bool {
        queryTokens.count >= 2 || !phraseCandidates.isEmpty || !anchorTokens.isEmpty
    }
}

@MainActor
final class SearchCoordinator: ObservableObject {
    private static let semanticTopicStopWords: Set<String> = [
        "a", "about", "after", "all", "an", "and", "are", "around", "as", "at", "be", "can",
        "chat", "conversations", "discussion", "discussions", "for", "from", "give", "in",
        "latest", "me", "my", "of", "on", "or", "quick", "recap", "show", "summary", "summarize",
        "tell", "the", "these", "this", "those", "to", "updates", "what", "with"
    ]
    private static let semanticShortKeepers: Set<String> = ["bd", "pm", "qa", "ui", "ux"]
    private static let semanticTopicQualifierTokens: Set<String> = [
        "addresses", "address", "api", "app", "apps", "bounties", "bounty", "case", "cases",
        "contract", "contracts", "ideas", "key", "keys", "mobile", "notification", "office",
        "recordings", "screenshot", "screenshots", "smart", "space", "study", "studies",
        "swap", "tweet", "wallet", "whitelist", "whitelisted", "whitelisting"
    ]
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
        let topicContext = semanticTopicContext(for: query)

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
        var candidatesByChatId = buildLocalSemanticCandidates(
            from: mergedHits,
            chatsById: chatById,
            queryContext: topicContext
        )
        mergeTitleSemanticCandidates(
            query: query,
            queryContext: topicContext,
            chats: scopedChats,
            candidatesByChatId: &candidatesByChatId
        )

        let candidates = Array(candidatesByChatId.values)
            .filter { semanticCandidatePassesTopicGuard($0, queryContext: topicContext) }
            .sorted { (lhs: LocalSemanticChatCandidate, rhs: LocalSemanticChatCandidate) in
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
        chatsById: [Int64: TGChat],
        queryContext: SemanticTopicQueryContext
    ) -> [Int64: LocalSemanticChatCandidate] {
        var groupedHits: [Int64: [LocalSemanticMessageScore]] = [:]
        for hit in mergedHits {
            groupedHits[hit.message.chatId, default: []].append(hit)
        }

        var bestByChatId: [Int64: LocalSemanticChatCandidate] = [:]

        for (chatId, hits) in groupedHits {
            guard let chat = chatsById[chatId] else { continue }

            let scoredHits = hits.map { hit -> (hit: LocalSemanticMessageScore, queryMatches: Int, phraseMatches: Int, anchorMatches: Int, totalScore: Double) in
                let text = hit.message.textContent ?? hit.message.displayText
                let queryMatches = countSemanticMatches(in: text, terms: queryContext.queryTokens)
                let phraseMatches = countSemanticMatches(in: text, terms: queryContext.phraseCandidates)
                let anchorMatches = countSemanticMatches(in: text, terms: queryContext.anchorTokens)
                let totalScore =
                    semanticMessageScore(hit)
                    + (Double(queryMatches) * 0.18)
                    + (Double(phraseMatches) * 0.50)
                    + (Double(anchorMatches) * 0.45)
                return (hit, queryMatches, phraseMatches, anchorMatches, totalScore)
            }.sorted { lhs, rhs in
                if lhs.totalScore != rhs.totalScore {
                    return lhs.totalScore > rhs.totalScore
                }
                if lhs.hit.message.date != rhs.hit.message.date {
                    return lhs.hit.message.date > rhs.hit.message.date
                }
                return lhs.hit.message.id > rhs.hit.message.id
            }

            guard let best = scoredHits.first else { continue }
            let snippet = semanticSnippet(from: best.hit.message.textContent ?? best.hit.message.displayText)

            let queryCoverage = semanticCoverage(
                in: scoredHits.map(\.hit.message),
                terms: queryContext.queryTokens
            )
            let phraseCoverage = semanticCoverage(
                in: scoredHits.map(\.hit.message),
                terms: queryContext.phraseCandidates
            )
            let anchorCoverage = semanticCoverage(
                in: scoredHits.map(\.hit.message),
                terms: queryContext.anchorTokens
            )

            let candidate = LocalSemanticChatCandidate(
                chat: chat,
                bestMessage: best.hit.message,
                bestSnippet: snippet,
                sortDate: best.hit.message.date,
                ftsScore: best.hit.ftsScore,
                vectorScore: best.hit.vectorScore,
                titleScore: 0,
                fallbackScore: 0,
                queryCoverage: queryCoverage,
                phraseCoverage: phraseCoverage,
                anchorCoverage: anchorCoverage,
                bestQueryMatches: best.queryMatches,
                bestPhraseMatches: best.phraseMatches,
                bestAnchorMatches: best.anchorMatches,
                matchedMessageCount: min(scoredHits.count, 5)
            )
            bestByChatId[chat.id] = candidate
        }

        return bestByChatId
    }

    private func mergeTitleSemanticCandidates(
        query: String,
        queryContext: SemanticTopicQueryContext,
        chats: [TGChat],
        candidatesByChatId: inout [Int64: LocalSemanticChatCandidate]
    ) {
        for chat in chats {
            let titleScore = normalizedTitleMatchScore(query: query, title: chat.title)
            guard titleScore > 0 else { continue }
            if queryContext.requiresGuardedTopicRanking
                && candidatesByChatId[chat.id] == nil
                && titleScore < 0.99 {
                continue
            }

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
                fallbackScore: 0,
                queryCoverage: 0,
                phraseCoverage: 0,
                anchorCoverage: 0,
                bestQueryMatches: 0,
                bestPhraseMatches: 0,
                bestAnchorMatches: 0,
                matchedMessageCount: 0
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

        score += Double(candidate.queryCoverage) * 0.45
        score += Double(candidate.phraseCoverage) * 1.2
        score += Double(candidate.anchorCoverage) * 0.9
        score += Double(candidate.bestQueryMatches) * 0.18
        score += Double(candidate.bestPhraseMatches) * 0.50
        score += Double(candidate.bestAnchorMatches) * 0.45
        score += Double(min(candidate.matchedMessageCount, 4)) * 0.05

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

    private func semanticTopicContext(for query: String) -> SemanticTopicQueryContext {
        let normalized = query
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\s-]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let focusPrefixes = [
            "what's latest with ",
            "what is latest with ",
            "show me discussions about ",
            "show me discussion about ",
            "show me chats about ",
            "show me messages about ",
            "show me conversations about "
        ]

        let focusQuery = focusPrefixes.first(where: { normalized.hasPrefix($0) }).map {
            String(normalized.dropFirst($0.count))
        } ?? normalized

        let queryTokens = semanticTopicTokens(from: normalized)
        let focusTokens = semanticTopicTokens(from: focusQuery)

        var phraseCandidates: [String] = []
        if focusTokens.count >= 2 {
            phraseCandidates.append(focusTokens.joined(separator: " "))
            for index in 0..<(focusTokens.count - 1) {
                phraseCandidates.append("\(focusTokens[index]) \(focusTokens[index + 1])")
            }
        }
        if focusTokens.count >= 3 {
            for index in 0..<(focusTokens.count - 2) {
                phraseCandidates.append("\(focusTokens[index]) \(focusTokens[index + 1]) \(focusTokens[index + 2])")
            }
        }
        phraseCandidates.append(contentsOf: singularizedPhraseCandidates(from: phraseCandidates))

        var anchorTokens: [String] = []
        for token in focusTokens {
            if !anchorTokens.isEmpty && Self.semanticTopicQualifierTokens.contains(token) {
                break
            }
            anchorTokens.append(token)
        }
        if anchorTokens.count == focusTokens.count && anchorTokens.count > 2 {
            anchorTokens = []
        }

        return SemanticTopicQueryContext(
            query: normalized,
            focusQuery: focusQuery,
            queryTokens: queryTokens,
            phraseCandidates: Array(NSOrderedSet(array: phraseCandidates)) as? [String] ?? phraseCandidates,
            anchorTokens: anchorTokens
        )
    }

    private func semanticTopicTokens(from text: String) -> [String] {
        let cleaned = text
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\s-]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        let tokens = cleaned
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter {
                !$0.isEmpty
                && !Self.semanticTopicStopWords.contains($0)
                && ($0.count >= 3 || Self.semanticShortKeepers.contains($0))
            }

        return Array(NSOrderedSet(array: tokens)) as? [String] ?? tokens
    }

    private func singularizedPhraseCandidates(from phrases: [String]) -> [String] {
        phrases.compactMap { phrase in
            let parts = phrase.split(separator: " ").map(String.init)
            guard var last = parts.last, last.count > 3, last.hasSuffix("s") else { return nil }
            last.removeLast()
            let singularized = Array(parts.dropLast()) + [last]
            return singularized.joined(separator: " ")
        }
    }

    private func countSemanticMatches(in text: String, terms: [String]) -> Int {
        guard !terms.isEmpty else { return 0 }
        let normalized = normalizedSemanticText(text)
        return terms.reduce(into: 0) { count, term in
            if normalized.contains(term) {
                count += 1
            }
        }
    }

    private func semanticCoverage(in messages: [TGMessage], terms: [String]) -> Int {
        guard !terms.isEmpty else { return 0 }
        let matched = Set(terms.filter { term in
            messages.contains { message in
                normalizedSemanticText(message.textContent ?? message.displayText).contains(term)
            }
        })
        return matched.count
    }

    private func normalizedSemanticText(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\s-]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func semanticCandidatePassesTopicGuard(
        _ candidate: LocalSemanticChatCandidate,
        queryContext: SemanticTopicQueryContext
    ) -> Bool {
        guard queryContext.requiresGuardedTopicRanking else { return true }

        let hasStrongHistorySignal = candidate.ftsScore > 0 || candidate.vectorScore >= 0.5
        let minimumQueryCoverage = max(1, min(2, queryContext.queryTokens.count))

        if candidate.queryCoverage < minimumQueryCoverage {
            return false
        }
        if !queryContext.anchorTokens.isEmpty && candidate.anchorCoverage == 0 {
            return false
        }
        if !queryContext.phraseCandidates.isEmpty
            && candidate.phraseCoverage == 0
            && candidate.bestPhraseMatches == 0
            && candidate.bestQueryMatches < minimumQueryCoverage {
            return false
        }
        if !hasStrongHistorySignal && candidate.titleScore < 0.99 {
            return false
        }
        if candidate.bestQueryMatches == 0 && candidate.bestPhraseMatches == 0 && candidate.titleScore < 0.99 {
            return false
        }

        return true
    }

    #if DEBUG
    func semanticResultsForTesting(
        query: String,
        scope: QueryScope,
        scopedChats: [TGChat],
        telegramService: TelegramService,
        aiService: AIService
    ) async -> [SemanticSearchResult] {
        await executeLocalSemanticSearch(
            query: query,
            scope: scope,
            scopedChats: scopedChats,
            telegramService: telegramService,
            aiService: aiService
        ).compactMap { result in
            guard case .semanticResult(let semantic) = result else { return nil }
            return semantic
        }
    }
    #endif

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
