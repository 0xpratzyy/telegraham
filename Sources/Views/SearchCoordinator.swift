import Foundation
import Combine
import TDLibKit

enum AISearchResult: Identifiable {
    case semanticResult(SemanticSearchResult)
    case agenticResult(AgenticSearchResult)

    var id: String {
        switch self {
        case .semanticResult(let result): return "sem-\(result.id)"
        case .agenticResult(let result): return "ag-\(result.id)"
        }
    }

    func linkedChat(in chats: [TGChat]) -> TGChat? {
        switch self {
        case .semanticResult(let result):
            return chats.first(where: { $0.id == result.chatId })
        case .agenticResult(let result):
            return chats.first(where: { $0.id == result.chatId })
        }
    }
}

private struct LocalSemanticMessageScore {
    let message: TGMessage
    var ftsScore: Double
    var vectorScore: Double

    var combinedScore: Double {
        (ftsScore * AppConstants.AI.SemanticSearch.ftsWeight)
        + (vectorScore * AppConstants.AI.SemanticSearch.vectorWeight)
    }
}

private struct LocalSemanticChatCandidate {
    let chat: TGChat
    let bestMessage: TGMessage
    let bestSnippet: String
    let combinedScore: Double
    let ftsScore: Double
    let vectorScore: Double
}

@MainActor
final class SearchCoordinator: ObservableObject {
    @Published var searchResultChatIds: Set<Int64> = []
    @Published var isSearching = false
    @Published var aiResults: [AISearchResult] = []
    @Published var aiSearchMode: QueryIntent? = nil
    @Published var isAISearching = false
    @Published var aiSearchError: String?
    @Published var currentQuerySpec: QuerySpec?
    @Published var agenticDebugInfo: AgenticDebugInfo?
    @Published var semanticMatchedChats: Int = 0
    @Published var totalChatsToScan: Int = 0

    private var searchTask: Task<Void, Never>?
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
        isAISearching = false
        aiSearchError = nil
        currentQuerySpec = nil
        agenticDebugInfo = nil
        semanticMatchedChats = 0
        totalChatsToScan = 0
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

        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }

            let parsedSpec = queryInterpreter.parse(
                query: query,
                now: Date(),
                timezone: .current,
                activeFilter: activeScope
            )
            let intent = await aiService.queryRouter.route(
                query: query,
                querySpec: parsedSpec,
                activeFilter: activeScope,
                timezone: .current,
                now: Date()
            )
            guard !Task.isCancelled else { return }

            if intent != .messageSearch && aiService.isConfigured {
                aiSearchMode = intent
                isAISearching = true
                aiSearchError = nil
                currentQuerySpec = parsedSpec
                searchResultChatIds = []

                do {
                    let results = try await executeAISearch(
                        intent: intent,
                        query: query,
                        querySpec: parsedSpec,
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
                } catch {
                    guard !Task.isCancelled else { return }
                    aiSearchError = error.localizedDescription
                    isAISearching = false
                }
            } else {
                aiSearchMode = nil
                aiResults = []
                aiSearchError = nil
                currentQuerySpec = nil
                agenticDebugInfo = nil
                isSearching = true

                do {
                    let scopedChats = scopedChats(from: visibleChats, scope: activeScope)
                    let scopedChatIds = Set(scopedChats.map(\.id))
                    let localMessages = await telegramService.localSearch(
                        query: query,
                        chatIds: scopedChats.map(\.id),
                        limit: 50
                    )
                    let unindexedChatIds = await DatabaseManager.shared.unindexedChatIds(in: scopedChats.map(\.id))

                    var mergedMessages = Dictionary(
                        uniqueKeysWithValues: localMessages.map { message in
                            ("\(message.chatId):\(message.id)", message)
                        }
                    )

                    if !unindexedChatIds.isEmpty {
                        let fallbackMessages = try await telegramService.searchMessages(
                            query: query,
                            limit: 50,
                            chatTypeFilter: keywordFallbackChatTypeFilter(for: activeScope)
                        )

                        for message in fallbackMessages
                        where scopedChatIds.contains(message.chatId) && unindexedChatIds.contains(message.chatId) {
                            mergedMessages["\(message.chatId):\(message.id)"] = message
                        }
                    }

                    guard !Task.isCancelled else { return }
                    searchResultChatIds = Set(mergedMessages.values.map(\.chatId))
                    isSearching = false
                } catch {
                    guard !Task.isCancelled else { return }
                    isSearching = false
                }
            }
        }
    }

    private func executeAISearch(
        intent: QueryIntent,
        query: String,
        querySpec: QuerySpec?,
        activeScope: QueryScope,
        aiSearchSourceChats: [TGChat],
        scopedAISearchSourceChats: [TGChat],
        includeBotsInAISearch: Bool,
        telegramService: TelegramService,
        aiService: AIService,
        pipelineCategoryProvider: @escaping (Int64) -> FollowUpItem.Category?,
        pipelineHintProvider: @escaping (Int64) async -> String
    ) async throws -> [AISearchResult] {
        switch intent {
        case .semanticSearch:
            return await executeLocalSemanticSearch(
                query: query,
                scopedChats: scopedAISearchSourceChats,
                telegramService: telegramService,
                aiService: aiService
            )
        case .agenticSearch:
            return try await executeAgenticSearch(
                query: query,
                querySpec: querySpec,
                activeScope: activeScope,
                aiSearchSourceChats: aiSearchSourceChats,
                includeBotsInAISearch: includeBotsInAISearch,
                telegramService: telegramService,
                aiService: aiService,
                pipelineCategoryProvider: pipelineCategoryProvider,
                pipelineHintProvider: pipelineHintProvider
            )
        case .messageSearch:
            return []
        }
    }

    private func executeLocalSemanticSearch(
        query: String,
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
        let candidates = buildLocalSemanticCandidates(from: mergedHits, chatsById: chatById)

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
            if lhs.combinedScore != rhs.combinedScore {
                return lhs.combinedScore > rhs.combinedScore
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
    ) -> [LocalSemanticChatCandidate] {
        var bestByChatId: [Int64: LocalSemanticChatCandidate] = [:]

        for hit in mergedHits {
            guard let chat = chatsById[hit.message.chatId] else { continue }
            let snippet = semanticSnippet(from: hit.message.textContent ?? hit.message.displayText)

            let candidate = LocalSemanticChatCandidate(
                chat: chat,
                bestMessage: hit.message,
                bestSnippet: snippet,
                combinedScore: hit.combinedScore,
                ftsScore: hit.ftsScore,
                vectorScore: hit.vectorScore
            )

            if let existing = bestByChatId[chat.id], existing.combinedScore >= candidate.combinedScore {
                continue
            }
            bestByChatId[chat.id] = candidate
        }

        return bestByChatId.values.sorted { lhs, rhs in
            if lhs.combinedScore != rhs.combinedScore {
                return lhs.combinedScore > rhs.combinedScore
            }
            if lhs.bestMessage.date != rhs.bestMessage.date {
                return lhs.bestMessage.date > rhs.bestMessage.date
            }
            return lhs.chat.id < rhs.chat.id
        }
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
        if candidate.ftsScore > 0 && candidate.vectorScore > 0 {
            return "Matched both keywords and semantic context"
        }
        if candidate.ftsScore > 0 {
            return "Strong keyword match in local history"
        }
        return "Strong semantic match in local history"
    }

    private func semanticRelevance(
        for candidate: LocalSemanticChatCandidate,
        rank: Int
    ) -> SemanticSearchResult.Relevance {
        let score = candidate.combinedScore
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

    private func keywordFallbackChatTypeFilter(for scope: QueryScope) -> SearchMessagesChatTypeFilter? {
        switch scope {
        case .all:
            return nil
        case .dms:
            return .searchMessagesChatTypeFilterPrivate
        case .groups:
            return .searchMessagesChatTypeFilterGroup
        }
    }
}
