import Foundation

@MainActor
final class SummaryEngine {
    static let shared = SummaryEngine()

    private struct LocalHit {
        let message: TGMessage
        var ftsScore: Double
        var vectorScore: Double
    }

    private struct QueryContext {
        let raw: String
        let normalized: String
        let queryTerms: [String]
        let scopedTerms: [String]
        let topicTerms: [String]
        let cluePhrases: [String]
        let requiresJointAnchor: Bool
        let retrievalQuery: String
    }

    private struct Candidate {
        let chat: TGChat
        let bestMessage: TGMessage?
        let bestSnippet: String
        let score: Double
        let queryCoverage: Int
        let jointAnchorHits: Int
        let topMessages: [TGMessage]
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
        let queryContext = buildQueryContext(querySpec.rawQuery)
        let retrievalQuery = queryContext.retrievalQuery.isEmpty ? querySpec.rawQuery : queryContext.retrievalQuery

        let ftsHits = await telegramService.localScoredSearch(
            query: retrievalQuery,
            chatIds: scopedChatIds,
            limit: constants.ftsTopMessages
        )
        let vectorHits = await telegramService.localVectorSearch(
            query: retrievalQuery,
            chatIds: scopedChatIds,
            limit: constants.vectorTopMessages
        )
        let senderFallbackHits = await scopedSenderFallbackHits(
            queryContext: queryContext,
            scopedChatIds: scopedChatIds,
            timeRange: querySpec.timeRange,
            fallbackLimit: constants.fallbackTopMessages,
            chatsById: chatById
        )

        let merged = applyTimeRange(
            merge(ftsHits: ftsHits, vectorHits: vectorHits, fallbackHits: senderFallbackHits),
            timeRange: querySpec.timeRange
        )
        let candidates = buildCandidates(
            from: merged,
            chatsById: chatById,
            queryContext: queryContext,
            timeRange: querySpec.timeRange
        )
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

          guard let focus = supportingCandidates.first,
                focus.score >= minimumFocusScore(for: queryContext) else {
              return SearchExecution(output: nil, results: supportingResults)
          }

          if queryContext.requiresJointAnchor && focus.jointAnchorHits == 0 {
              return SearchExecution(output: nil, results: supportingResults)
          }

          let focusMessages = await loadSummaryMessages(
              for: focus.chat,
              anchorMessage: focus.bestMessage,
            timeRange: querySpec.timeRange
        )
        let boundedMessages = boundedSummaryMessages(
            from: focusMessages,
            anchorMessage: focus.bestMessage,
            queryContext: queryContext
        )

        let summaryText = await summarize(
            query: querySpec.rawQuery,
            chat: focus.chat,
            messages: boundedMessages,
            aiService: aiService,
            fallbackSnippet: focus.bestSnippet,
            queryContext: queryContext
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
        vectorHits: [TelegramService.LocalMessageSearchHit],
        fallbackHits: [LocalHit]
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

        for hit in fallbackHits {
            let key = "\(hit.message.chatId):\(hit.message.id)"
            if var existing = byKey[key] {
                existing.ftsScore = max(existing.ftsScore, hit.ftsScore)
                existing.vectorScore = max(existing.vectorScore, hit.vectorScore)
                byKey[key] = existing
            } else {
                byKey[key] = hit
            }
        }

        return Array(byKey.values)
    }

    private func buildCandidates(
        from hits: [LocalHit],
        chatsById: [Int64: TGChat],
        queryContext: QueryContext,
        timeRange: TimeRangeConstraint?
    ) -> [Candidate] {
        struct RankedHit {
            let hit: LocalHit
            let baseScore: Double
            let matchedQueryTerms: Set<String>
            let matchedScopedTerms: Set<String>
            let matchedTopicTerms: Set<String>
            let matchedCluePhrases: Set<String>
            let titleMatches: Int
            let jointAnchor: Bool
            let summaryAnchor: Bool
            let inTimeRange: Bool
            let hasSubstantiveBodyText: Bool
        }

        var grouped: [Int64: [RankedHit]] = [:]

        for hit in hits {
            guard let chat = chatsById[hit.message.chatId] else { continue }
            let baseScore =
                (hit.ftsScore * AppConstants.AI.SemanticSearch.ftsWeight) +
                (hit.vectorScore * AppConstants.AI.SemanticSearch.vectorWeight) +
                (chat.chatType.isPrivate ? 0.08 : 0)

            let normalizedText = normalize(searchableText(for: hit.message))
            let normalizedTitle = normalize(chat.title)
            let matchedQueryTerms = Set(queryContext.queryTerms.filter { normalizedText.contains($0) })
            let matchedScopedTerms = Set(queryContext.scopedTerms.filter {
                normalizedText.contains($0) || normalizedTitle.contains($0)
            })
            let matchedTopicTerms = Set(queryContext.topicTerms.filter {
                normalizedText.contains($0) || normalizedTitle.contains($0)
            })
            let matchedCluePhrases = Set(queryContext.cluePhrases.filter { normalizedText.contains($0) })
            let titleMatches = queryContext.queryTerms.filter { normalizedTitle.contains($0) }.count
            let jointAnchor = !matchedScopedTerms.isEmpty && !matchedTopicTerms.isEmpty
            let summaryAnchor = isSummaryAnchor(text: normalizedText)
            let hasSubstantiveBodyText = hasSubstantiveBodyText(hit.message)

            let rankedHit = RankedHit(
                hit: hit,
                baseScore: baseScore,
                matchedQueryTerms: matchedQueryTerms,
                matchedScopedTerms: matchedScopedTerms,
                matchedTopicTerms: matchedTopicTerms,
                matchedCluePhrases: matchedCluePhrases,
                titleMatches: titleMatches,
                jointAnchor: jointAnchor,
                summaryAnchor: summaryAnchor,
                inTimeRange: timeRange?.contains(hit.message.date) ?? true,
                hasSubstantiveBodyText: hasSubstantiveBodyText
            )
            grouped[chat.id, default: []].append(rankedHit)
        }

        return grouped.compactMap { chatId, rankedHits in
            guard let chat = chatsById[chatId] else { return nil }
            let sortedHits = rankedHits.sorted {
                if $0.hasSubstantiveBodyText != $1.hasSubstantiveBodyText {
                    return $0.hasSubstantiveBodyText && !$1.hasSubstantiveBodyText
                }
                if $0.baseScore != $1.baseScore { return $0.baseScore > $1.baseScore }
                return $0.hit.message.date > $1.hit.message.date
            }
            guard let best = sortedHits.first else { return nil }

            let matchedQueryTerms = Set(sortedHits.flatMap(\.matchedQueryTerms))
            let matchedScopedTerms = Set(sortedHits.flatMap(\.matchedScopedTerms))
            let matchedTopicTerms = Set(sortedHits.flatMap(\.matchedTopicTerms))
            let matchedCluePhrases = Set(sortedHits.flatMap(\.matchedCluePhrases))
            let summaryAnchors = sortedHits.filter(\.summaryAnchor).count
            let jointAnchors = sortedHits.filter(\.jointAnchor).count
            let inRangeHits = sortedHits.filter(\.inTimeRange).count
            let substantiveBodyHits = sortedHits.filter(\.hasSubstantiveBodyText).count
            let titleMatches = sortedHits.map(\.titleMatches).max() ?? 0

            var aggregate = best.baseScore * 3.4
            aggregate += sortedHits.dropFirst().prefix(2).reduce(0) { $0 + max(0, $1.baseScore) * 0.55 }
            aggregate += Double(matchedQueryTerms.count) * 0.45
            aggregate += Double(matchedScopedTerms.count) * 0.85
            aggregate += Double(matchedTopicTerms.count) * 0.55
            aggregate += Double(matchedCluePhrases.count) * 0.65
            aggregate += Double(summaryAnchors) * 0.22
            aggregate += Double(jointAnchors) * 1.1
            aggregate += Double(inRangeHits) * 0.12
            aggregate += Double(min(substantiveBodyHits, 3)) * 0.78
            aggregate += Double(titleMatches) * 0.95
            if chat.chatType.isPrivate { aggregate += 0.08 }

            if queryContext.requiresJointAnchor && jointAnchors == 0 {
                aggregate -= 2.2
            }
            if !queryContext.queryTerms.isEmpty && matchedQueryTerms.count < min(2, queryContext.queryTerms.count) {
                aggregate -= 0.9
            }
            if titleMatches > 0 && substantiveBodyHits == 0 {
                aggregate -= 1.45
            }

            return Candidate(
                chat: chat,
                bestMessage: best.hit.message,
                bestSnippet: snippet(from: best.hit.message.displayText),
                score: aggregate,
                queryCoverage: matchedQueryTerms.count,
                jointAnchorHits: jointAnchors,
                topMessages: Array(sortedHits.prefix(8).map(\.hit.message))
            )
        }
    }

    private func summarize(
        query: String,
        chat: TGChat,
        messages: [TGMessage],
        aiService: AIService,
        fallbackSnippet: String,
        queryContext: QueryContext
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

        let topFallbackSnippets = rankedSupportMessages(messages, queryContext: queryContext)
            .prefix(AppConstants.Search.Summary.fallbackSnippetLimit + 2)
            .map { snippet(from: $0.displayText) }

        let joined = topFallbackSnippets.joined(separator: " • ")
        if !joined.isEmpty {
            return joined
        }
        return fallbackSnippet
    }

    private func loadSummaryMessages(
        for chat: TGChat,
        anchorMessage: TGMessage?,
        timeRange: TimeRangeConstraint?
    ) async -> [TGMessage] {
        let cachedMessages = await MessageCacheService.shared.getMessages(chatId: chat.id) ?? []

        let fetchLimit = timeRange == nil
            ? AppConstants.Search.Summary.summaryMessageLimit * 4
            : AppConstants.Search.Summary.summaryMessageLimit * 6
        let localRecords = await DatabaseManager.shared.loadMessages(
            chatId: chat.id,
            startDate: timeRange?.startDate,
            endDate: timeRange?.endDate,
            limit: fetchLimit
        )
        let localMessages = localRecords.map { record in
            let senderId: TGMessage.MessageSenderId = if let senderUserId = record.senderUserId {
                .user(senderUserId)
            } else {
                .chat(record.chatId)
            }
            return TGMessage(
                id: record.id,
                chatId: record.chatId,
                senderId: senderId,
                date: record.date,
                textContent: record.textContent,
                mediaType: record.mediaTypeRaw.flatMap(TGMessage.MediaType.init(rawValue:)),
                isOutgoing: record.isOutgoing,
                chatTitle: chat.title,
                senderName: record.senderName
            )
        }

        let mergedMessages = mergeSummarySources(cached: cachedMessages, local: localMessages)
        return expandedAnchorWindow(
            in: applyTimeRange(mergedMessages, timeRange: timeRange),
            anchorMessage: anchorMessage
        )
    }

    private func mergeSummarySources(cached: [TGMessage], local: [TGMessage]) -> [TGMessage] {
        var byMessageId: [Int64: TGMessage] = [:]
        for message in cached + local {
            byMessageId[message.id] = message
        }
        return byMessageId.values.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id > $1.id
        }
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

    private func normalize(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func buildQueryContext(_ rawQuery: String) -> QueryContext {
        let normalized = normalize(rawQuery)
        let queryTerms = Array(NSOrderedSet(array: normalized
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "@" && $0 != "." && $0 != "-" })
            .map(String.init)
            .filter { token in
                !token.isEmpty
                    && !summaryStopWords.contains(token)
                    && token.count >= 3
            })) as? [String] ?? []
        let scopedTerms = extractScopedTerms(from: normalized)
        let cluePhrases = [
            "what did we decide", "what happened", "key takeaways", "latest context",
            "catch me up", "full rankings", "team brief", "main gaps", "feedback",
            "overview", "full picture"
        ].filter { normalized.contains($0) }
        let genericSummaryTokens = Set(cluePhrases.flatMap { clue in
            clue
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { !$0.isEmpty }
        })
        let topicTerms = queryTerms.filter {
            !scopedTerms.contains($0) && !genericSummaryTokens.contains($0)
        }
        return QueryContext(
            raw: rawQuery,
            normalized: normalized,
            queryTerms: queryTerms,
            scopedTerms: scopedTerms,
            topicTerms: topicTerms,
            cluePhrases: cluePhrases,
            requiresJointAnchor: !scopedTerms.isEmpty && !topicTerms.isEmpty,
            retrievalQuery: buildRetrievalQuery(scopedTerms: scopedTerms, topicTerms: topicTerms, fallbackQueryTerms: queryTerms)
        )
    }

    private func buildRetrievalQuery(
        scopedTerms: [String],
        topicTerms: [String],
        fallbackQueryTerms: [String]
    ) -> String {
        let preferred = scopedTerms + topicTerms
        let tokens = preferred.isEmpty ? fallbackQueryTerms : preferred
        let uniqueTokens = (Array(NSOrderedSet(array: tokens)) as? [String]) ?? tokens
        return uniqueTokens.joined(separator: " ")
    }

    #if DEBUG
    func retrievalQueryForTesting(_ rawQuery: String) -> String {
        buildQueryContext(rawQuery).retrievalQuery
    }
    #endif

    private func extractScopedTerms(from normalized: String) -> [String] {
        let patterns = [
            #"\bwith\s+([a-z0-9@.\- ]+?)(?:\s+(?:from|about|last|this|today|yesterday|thread|chat|conversation|project)\b|[?.!]|$)"#,
            #"\babout\s+([a-z0-9@.\- ]+?)(?:\s+(?:from|last|this|today|yesterday|thread|chat|conversation|project)\b|[?.!]|$)"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let nsRange = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
            guard let match = regex.firstMatch(in: normalized, options: [], range: nsRange),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: normalized) else {
                continue
            }
            let extracted = String(normalized[range])
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "@" && $0 != "." })
                .map(String.init)
                .filter {
                    !$0.isEmpty
                        && !summaryStopWords.contains($0)
                        && $0.count >= 3
                }
            if !extracted.isEmpty {
                return Array(NSOrderedSet(array: extracted)) as? [String] ?? extracted
            }
        }
        return []
    }

    private func minimumFocusScore(for queryContext: QueryContext) -> Double {
        queryContext.requiresJointAnchor ? 1.25 : 0.95
    }

    private func expandedAnchorWindow(in messages: [TGMessage], anchorMessage: TGMessage?) -> [TGMessage] {
        let sorted = messages.sorted { $0.date < $1.date }
        guard let anchorMessage,
              let anchorIndex = sorted.firstIndex(where: { $0.id == anchorMessage.id }) else {
            return sorted
        }
        let lowerBound = max(0, anchorIndex - 6)
        let upperBound = min(sorted.count - 1, anchorIndex + 6)
        return Array(sorted[lowerBound...upperBound])
    }

    private func boundedSummaryMessages(
        from messages: [TGMessage],
        anchorMessage: TGMessage?,
        queryContext: QueryContext
    ) -> [TGMessage] {
        guard !messages.isEmpty else {
            return anchorMessage.map { [$0] } ?? []
        }
        let ranked = rankedSupportMessages(messages, queryContext: queryContext)
        let selected = Array(ranked.prefix(6)).sorted { $0.date < $1.date }
        return selected.isEmpty ? Array(messages.sorted { $0.date < $1.date }.suffix(AppConstants.Search.Summary.summaryMessageLimit)) : selected
    }

    private func rankedSupportMessages(_ messages: [TGMessage], queryContext: QueryContext) -> [TGMessage] {
        messages
            .sorted {
                let lhs = supportScore(for: $0, queryContext: queryContext)
                let rhs = supportScore(for: $1, queryContext: queryContext)
                if lhs != rhs { return lhs > rhs }
                return $0.date > $1.date
            }
    }

    private func supportScore(for message: TGMessage, queryContext: QueryContext) -> Double {
        let text = normalize(searchableText(for: message))
        var score = Double(queryContext.queryTerms.filter { text.contains($0) }.count) * 2.2
        score += Double(queryContext.scopedTerms.filter { text.contains($0) }.count) * 3.0
        score += Double(queryContext.topicTerms.filter { text.contains($0) }.count) * 2.5
        score += Double(queryContext.cluePhrases.filter { text.contains($0) }.count) * 3.2
        if isSummaryAnchor(text: text) { score += 2.5 }
        if text.count < 90 && shortLowSignalPrefixes.contains(where: { text.hasPrefix($0) }) {
            score -= 3.0
        }
        score += min(Double(text.count), 500) / 250.0
        return score
    }

    private func isSummaryAnchor(text: String) -> Bool {
        [
            "summary", "overview", "bottom line", "full picture", "decided",
            "thought we", "main gaps", "feedback:", "team brief", "rankings",
            "compiled up here", "what we discussed", "in summary"
        ].contains(where: text.contains)
    }

    private func applyTimeRange(_ hits: [LocalHit], timeRange: TimeRangeConstraint?) -> [LocalHit] {
        guard let timeRange else { return hits }
        return hits.filter { timeRange.contains($0.message.date) }
    }

    private func applyTimeRange(_ messages: [TGMessage], timeRange: TimeRangeConstraint?) -> [TGMessage] {
        guard let timeRange else { return messages }
        return messages.filter { timeRange.contains($0.date) }
    }

    private func snippet(from text: String) -> String {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return String(normalized.prefix(AppConstants.AI.SemanticSearch.messagePreviewCharacterLimit))
    }

    private let summaryStopWords: Set<String> = [
        "what", "did", "we", "with", "the", "a", "an", "and", "or", "to", "of", "for",
        "me", "my", "our", "about", "give", "quick", "summary", "summarize", "summarise",
        "recap", "last", "week", "month", "from", "this", "that", "right", "now", "after",
        "happened", "discuss", "discussed", "conclude", "concluded", "decide", "decided",
        "main", "gaps", "chat", "chats", "thread", "conversation", "are", "is", "was", "were"
    ]

    private let shortLowSignalPrefixes = [
        "check ", "tell ", "digging into it", "hetzner se compare", "what's the context",
        "yoo", "whoop", "wispr", "lemme know"
    ]

    private func searchableText(for message: TGMessage) -> String {
        [message.senderName, message.displayText]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    private func hasSubstantiveBodyText(_ message: TGMessage) -> Bool {
        guard let text = message.textContent?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return false
        }
        return text.count >= 18
    }

    private func scopedSenderFallbackHits(
        queryContext: QueryContext,
        scopedChatIds: [Int64],
        timeRange: TimeRangeConstraint?,
        fallbackLimit: Int,
        chatsById: [Int64: TGChat]
    ) async -> [LocalHit] {
        guard !queryContext.scopedTerms.isEmpty, queryContext.topicTerms.isEmpty else {
            return []
        }

        let records = await DatabaseManager.shared.loadMessagesMatchingSenderTerms(
            chatIds: scopedChatIds,
            senderTerms: queryContext.scopedTerms,
            startDate: timeRange?.startDate,
            endDate: timeRange?.endDate,
            limit: fallbackLimit
        )

        return records.map { record in
            let senderId: TGMessage.MessageSenderId = if let senderUserId = record.senderUserId {
                .user(senderUserId)
            } else {
                .chat(record.chatId)
            }
            let message = TGMessage(
                id: record.id,
                chatId: record.chatId,
                senderId: senderId,
                date: record.date,
                textContent: record.textContent,
                mediaType: record.mediaTypeRaw.flatMap(TGMessage.MediaType.init(rawValue:)),
                isOutgoing: record.isOutgoing,
                chatTitle: chatsById[record.chatId]?.title,
                senderName: record.senderName
            )
            return LocalHit(message: message, ftsScore: 0.55, vectorScore: 0)
        }
    }
}
