import Foundation

@MainActor
final class SummaryEngine {
    static let shared = SummaryEngine()

    private struct LocalHit {
        let message: TGMessage
        var ftsScore: Double
        var vectorScore: Double
    }

    private struct Candidate {
        let chat: TGChat
        let bestMessage: TGMessage?
        let bestSnippet: String
        let score: Double
    }

    struct SearchExecution {
        let output: SummarySearchOutput?
        let results: [SemanticSearchResult]
    }

    func search(
        query querySpec: QuerySpec,
        scope: QueryScope,
        scopedChats: [TGChat],
        telegramService: TelegramService,
        aiService: AIService
    ) async -> SearchExecution {
        guard !scopedChats.isEmpty else {
            return SearchExecution(output: nil, results: [])
        }

        let scopedChatIds = scopedChats.map(\.id)
        let chatById = Dictionary(uniqueKeysWithValues: scopedChats.map { ($0.id, $0) })
        let constants = AppConstants.AI.SemanticSearch.self

        let ftsHits = await telegramService.localScoredSearch(
            query: querySpec.rawQuery,
            chatIds: scopedChatIds,
            limit: constants.ftsTopMessages
        )
        let vectorHits = await telegramService.localVectorSearch(
            query: querySpec.rawQuery,
            chatIds: scopedChatIds,
            limit: constants.vectorTopMessages
        )

        let merged = merge(ftsHits: ftsHits, vectorHits: vectorHits)
        let candidates = buildCandidates(from: merged, chatsById: chatById)
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.chat.order > rhs.chat.order
            }

        let supportingCandidates = Array(candidates.prefix(AppConstants.Search.Summary.supportingResultLimit))
        let supportingResults = supportingCandidates.enumerated().map { index, candidate in
            SemanticSearchResult(
                chatId: candidate.chat.id,
                chatTitle: candidate.chat.title,
                reason: index == 0 ? "Best local summary context" : "Supporting local context",
                relevance: index == 0 ? .high : .medium,
                matchingMessages: [candidate.bestSnippet]
            )
        }

        guard let focus = supportingCandidates.first else {
            return SearchExecution(output: nil, results: supportingResults)
        }

        let focusMessages = await loadSummaryMessages(
            for: focus.chat,
            telegramService: telegramService
        )
        let boundedMessages = Array(
            focusMessages
                .sorted { $0.date < $1.date }
                .suffix(AppConstants.Search.Summary.summaryMessageLimit)
        )

        let summaryText = await summarize(
            query: querySpec.rawQuery,
            chat: focus.chat,
            messages: boundedMessages,
            aiService: aiService,
            fallbackSnippet: focus.bestSnippet
        )

        let output = SummarySearchOutput(
            summaryText: summaryText,
            title: summaryTitle(for: querySpec.rawQuery, chatTitle: focus.chat.title),
            supportingChatId: focus.chat.id,
            supportingMessageIds: boundedMessages.map(\.id)
        )

        return SearchExecution(output: output, results: supportingResults)
    }

    private func merge(
        ftsHits: [TelegramService.LocalMessageSearchHit],
        vectorHits: [TelegramService.LocalMessageSearchHit]
    ) -> [LocalHit] {
        let maxFTS = ftsHits.map(\.score).max() ?? 0
        let maxVector = vectorHits.map(\.score).max() ?? 0
        var byKey: [String: LocalHit] = [:]

        for hit in ftsHits {
            let key = "\(hit.message.chatId):\(hit.message.id)"
            let normalized = normalize(score: hit.score, maxScore: maxFTS)
            if var existing = byKey[key] {
                existing.ftsScore = max(existing.ftsScore, normalized)
                byKey[key] = existing
            } else {
                byKey[key] = LocalHit(message: hit.message, ftsScore: normalized, vectorScore: 0)
            }
        }

        for hit in vectorHits {
            let key = "\(hit.message.chatId):\(hit.message.id)"
            let normalized = normalize(score: hit.score, maxScore: maxVector)
            if var existing = byKey[key] {
                existing.vectorScore = max(existing.vectorScore, normalized)
                byKey[key] = existing
            } else {
                byKey[key] = LocalHit(message: hit.message, ftsScore: 0, vectorScore: normalized)
            }
        }

        return Array(byKey.values)
    }

    private func buildCandidates(
        from hits: [LocalHit],
        chatsById: [Int64: TGChat]
    ) -> [Candidate] {
        var bestByChatId: [Int64: Candidate] = [:]

        for hit in hits {
            guard let chat = chatsById[hit.message.chatId] else { continue }
            let score =
                (hit.ftsScore * AppConstants.AI.SemanticSearch.ftsWeight) +
                (hit.vectorScore * AppConstants.AI.SemanticSearch.vectorWeight) +
                (chat.chatType.isPrivate ? 0.08 : 0)

            let candidate = Candidate(
                chat: chat,
                bestMessage: hit.message,
                bestSnippet: snippet(from: hit.message.displayText),
                score: score
            )

            if let existing = bestByChatId[chat.id], existing.score >= candidate.score {
                continue
            }
            bestByChatId[chat.id] = candidate
        }

        return Array(bestByChatId.values)
    }

    private func summarize(
        query: String,
        chat: TGChat,
        messages: [TGMessage],
        aiService: AIService,
        fallbackSnippet: String
    ) async -> String {
        guard !messages.isEmpty else {
            return "Little recent context found in \(chat.title)."
        }

        let snippets = MessageSnippet.fromMessages(messages, chatTitle: chat.title)
        let systemPrompt = QuerySummaryPrompt.systemPrompt(query: query, chatTitle: chat.title)

        if aiService.isConfigured {
            do {
                return try await aiService.provider.summarize(messages: snippets, prompt: systemPrompt)
            } catch {
                // Fall through to local fallback summary.
            }
        }

        let topFallbackSnippets = messages
            .sorted { $0.date > $1.date }
            .prefix(AppConstants.Search.Summary.fallbackSnippetLimit)
            .map { snippet(from: $0.displayText) }

        let joined = topFallbackSnippets.joined(separator: " • ")
        if !joined.isEmpty {
            return joined
        }
        return fallbackSnippet
    }

    private func loadSummaryMessages(
        for chat: TGChat,
        telegramService: TelegramService
    ) async -> [TGMessage] {
        if let cached = await MessageCacheService.shared.getMessages(chatId: chat.id), !cached.isEmpty {
            return cached
        }
        return (try? await telegramService.getChatHistory(
            chatId: chat.id,
            limit: AppConstants.Search.Summary.summaryMessageLimit
        )) ?? []
    }

    private func summaryTitle(for query: String, chatTitle: String) -> String {
        if query.lowercased().contains("what did we decide") {
            return "Decision Summary"
        }
        return "Summary for \(chatTitle)"
    }

    private func normalize(score: Double, maxScore: Double) -> Double {
        guard maxScore > 0 else { return 0 }
        return min(1, max(0, score / maxScore))
    }

    private func snippet(from text: String) -> String {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return String(normalized.prefix(AppConstants.AI.SemanticSearch.messagePreviewCharacterLimit))
    }
}
