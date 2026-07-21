import Foundation

extension SummaryEngine {
    /// Result of map-reduce summarization. Caller needs both the final
    /// synthesized text AND the list of per-chat extracts so it can
    /// render chips for *only* the chats the AI found relevant —
    /// instead of showing every retrieval candidate with a random
    /// last-message snippet next to it.
    struct SummarizeResult {
        let text: String
        /// Chats that returned non-null extracts in the map step,
        /// ordered by perChatDigest order. Empty when AI is off,
        /// every chat returned NOT_RELEVANT, or the digest was empty.
        let extracts: [(chat: TGChat, text: String)]
    }

    /// Map-reduce summarization over the per-chat digests.
    ///
    /// MAP — for each digest, run a small AI call in parallel that
    /// either pulls out anything query-relevant from that one chat or
    /// declares it NOT_RELEVANT. Cheap, parallelizable, citations are
    /// implicit (each extract belongs to exactly one chat).
    ///
    /// REDUCE — feed the non-null extracts into a single synthesis
    /// call using `QuerySummaryPrompt`. The model now does only
    /// cross-chat compression (much easier than reading 100+ raw
    /// messages and deciding what's relevant in one shot).
    ///
    /// When no chat extract returns relevant content, we surface that
    /// honestly to the user (with a list of what was looked at) rather
    /// than the old "No clear local summary context found" refusal.
    func summarize(
        query: String,
        scopeDescription: String,
        perChatDigest: [PerChatDigest],
        aiService: AIService,
        fallbackSnippet: String,
        queryContext: QueryContext
    ) async -> SummarizeResult {
        guard !perChatDigest.isEmpty else {
            return SummarizeResult(
                text: "Little recent context found in \(scopeDescription).",
                extracts: []
            )
        }

        // AI not configured → mechanical fallback so the UI still
        // shows useful text (e.g. tests with type:.none, offline use).
        guard aiService.isConfigured else {
            return SummarizeResult(
                text: localFallbackSummary(
                    perChatDigest: perChatDigest,
                    queryContext: queryContext,
                    fallbackSnippet: fallbackSnippet
                ),
                extracts: []
            )
        }

        // MAP — parallel per-chat extraction.
        let extracts = await runPerChatExtraction(
            query: query,
            perChatDigest: perChatDigest,
            aiService: aiService
        )

        // REDUCE — synthesize across the non-null extracts.
        if !extracts.isEmpty {
            let synthesisInput = extracts.map { extract -> MessageSnippet in
                MessageSnippet(
                    messageId: 0,
                    senderFirstName: "extract",
                    text: extract.text,
                    relativeTimestamp: "summary",
                    chatId: extract.chat.id,
                    chatName: extract.chat.title
                )
            }
            let synthesisPrompt = QuerySummaryPrompt.systemPrompt(
                query: query,
                scopeDescription: scopeDescription
            )
            do {
                let synthesized = try await aiService.provider.summarize(
                    messages: synthesisInput,
                    prompt: synthesisPrompt
                )
                return SummarizeResult(text: synthesized, extracts: extracts)
            } catch {
                // Synthesis failed — return per-chat extracts inline so
                // the user gets something instead of nothing. Matches
                // the per-chat-grouped shape the synthesis prompt
                // would have produced.
                let inlined = extracts
                    .map { "**\($0.chat.title)** — \($0.text)" }
                    .joined(separator: "\n\n")
                return SummarizeResult(text: inlined, extracts: extracts)
            }
        }

        // Every chat returned NOT_RELEVANT. Surface what we looked at
        // so the user can broaden the query, rather than the old
        // "no context found" dead end.
        let chatList = perChatDigest
            .map { "- " + $0.candidate.chat.title }
            .joined(separator: "\n")
        let emptyText = """
            **Direct answer** — Nothing in the messages I checked answers that question directly.

            **What I looked at:**
            \(chatList)

            **Suggestion:** Try a broader phrasing or drop a specific term (e.g. keep just the person's name or just the topic).
            """
        return SummarizeResult(text: emptyText, extracts: [])
    }

    /// Run per-chat extraction prompts in parallel. Each returns
    /// either a non-empty extract string or nil (NOT_RELEVANT / AI
    /// error / empty digest). Results are returned in the order of the
    /// input `perChatDigest` array (so the focus chat leads when its
    /// extract is non-null).
    private func runPerChatExtraction(
        query: String,
        perChatDigest: [PerChatDigest],
        aiService: AIService
    ) async -> [(chat: TGChat, text: String)] {
        let provider = aiService.provider
        let indexedResults: [(Int, TGChat, String?)] =
            await withTaskGroup(of: (Int, TGChat, String?).self) { group in
                for (index, digest) in perChatDigest.enumerated() {
                    let chat = digest.candidate.chat
                    let snippets = MessageSnippet.fromMessages(
                        digest.messages,
                        chatTitle: chat.title
                    )
                    guard !snippets.isEmpty else {
                        group.addTask { (index, chat, nil) }
                        continue
                    }
                    let prompt = PerChatExtractionPrompt.systemPrompt(
                        query: query,
                        chatName: chat.title
                    )
                    group.addTask {
                        do {
                            let raw = try await provider.summarize(
                                messages: snippets,
                                prompt: prompt
                            )
                            let trimmed = raw
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if trimmed.isEmpty
                                || trimmed.uppercased().contains("NOT_RELEVANT") {
                                return (index, chat, nil)
                            }
                            return (index, chat, trimmed)
                        } catch {
                            return (index, chat, nil)
                        }
                    }
                }
                var collected: [(Int, TGChat, String?)] = []
                for await result in group {
                    collected.append(result)
                }
                return collected
            }
        return indexedResults
            .sorted { $0.0 < $1.0 }
            .compactMap { entry in
                guard let text = entry.2 else { return nil }
                return (entry.1, text)
            }
    }

    /// Old single-pass fallback used when AI isn't configured. Pulls
    /// top-ranked snippets from across all per-chat digests and
    /// joins them. Mechanical but better than empty.
    private func localFallbackSummary(
        perChatDigest: [PerChatDigest],
        queryContext: QueryContext,
        fallbackSnippet: String
    ) -> String {
        let allMessages = perChatDigest.flatMap { $0.messages }
        let topFallbackSnippets = rankedSupportMessages(allMessages, queryContext: queryContext)
            .prefix(AppConstants.Search.Summary.fallbackSnippetLimit + 2)
            .map { snippet(from: $0.displayText) }

        let joined = topFallbackSnippets.joined(separator: " • ")
        if !joined.isEmpty {
            return joined
        }
        return fallbackSnippet
    }

    func loadSummaryMessages(
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

    func loadSummaryMessages(
        for candidates: [Candidate],
        timeRange: TimeRangeConstraint?
    ) async -> [TGMessage] {
        var collected: [TGMessage] = []
        for candidate in candidates {
            let messages = await loadSummaryMessages(
                for: candidate.chat,
                anchorMessage: candidate.bestMessage,
                timeRange: timeRange
            )
            collected.append(contentsOf: messages)
        }
        return mergeSummarySources(cached: collected, local: [])
    }

    func mergeSummarySources(cached: [TGMessage], local: [TGMessage]) -> [TGMessage] {
        var byMessageId: [MessageKey: TGMessage] = [:]
        for message in cached + local {
            byMessageId[MessageKey(message)] = message
        }
        return byMessageId.values.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            if $0.chatId != $1.chatId { return $0.chatId < $1.chatId }
            return $0.id > $1.id
        }
    }

    func summaryTitle(for query: String, scopeLabel: String) -> String {
        if query.lowercased().contains("what did we decide") {
            return "Decision Summary"
        }
        return "Summary for \(scopeLabel)"
    }

    func normalize(score: Double, maxScore: Double) -> Double {
        guard maxScore > 0 else { return 0 }
        return min(1, max(0, score / maxScore))
    }

    /// Collapses runs of the same letter into one ("deeeeksha" -> "deksha",
    /// "akhilll" -> "akhil"). Used as a cheap fuzzy-match for people-name
    /// anchors so playful spellings still align with the canonical name
    /// the user typed in their query.
    func collapseRepeatedLetters(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var lastChar: Character? = nil
        for char in text {
            if char != lastChar {
                result.append(char)
                lastChar = char
            }
        }
        return result
    }

    func normalize(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    func summaryCandidates(
        from candidates: [Candidate],
        focus: Candidate,
        queryContext: QueryContext
    ) -> [Candidate] {
        // Always include the focus chat. Then walk the remaining candidates
        // (already sorted by score) and include any whose score is within
        // `multiChatScoreDelta` of the focus, up to `multiChatCandidateLimit`.
        // This works for ANY query — the previous version only fanned out
        // when the user mentioned a person by name, so topic queries like
        // "what did we decide about Vietnam invoicing" silently got squashed
        // to one chat even when 3+ chats had real signal.
        let limit = AppConstants.Search.Summary.multiChatCandidateLimit
        // "catch me up", "key takeaways", "what happened" — user explicitly
        // asked for a sweep, so be more inclusive than the default delta.
        let scoreDelta = queryContext.cluePhrases.isEmpty
            ? AppConstants.Search.Summary.multiChatScoreDelta
            : AppConstants.Search.Summary.multiChatScoreDeltaCatchUp
        let threshold = focus.score - scoreDelta

        // For catch-up queries ("catch me up", "key takeaways", etc.) the
        // user has explicitly asked for a broad sweep — trust the score
        // threshold and skip the strict person/topic anchor filters that
        // would otherwise drop chats where the name only appears in body
        // text or as a partial match.
        let isCatchUpMode = !queryContext.cluePhrases.isEmpty

        var selected: [Candidate] = [focus]
        for candidate in candidates {
            if candidate.chat.id == focus.chat.id { continue }
            guard selected.count < limit else { break }
            guard candidate.score >= threshold else { break }

            if !isCatchUpMode {
                // Person-scoped queries keep their stricter rule: a near-focus
                // candidate must actually contain the person's name. Otherwise
                // a high-scoring chat about a different topic could sneak in.
                if !queryContext.senderFallbackTerms.isEmpty,
                   candidate.personAnchorHits == 0 {
                    continue
                }
                // (Joint-anchor was a hard drop here. Now soft — the
                // -1.0 score penalty in buildCandidates already pushes
                // candidates without a joint anchor below the focus
                // unless they have strong independent FTS/vector signal,
                // in which case they're worth including.)
            }
            selected.append(candidate)
        }
        return selected
    }

    func summaryScopeDescription(
        from candidates: [Candidate],
        queryContext: QueryContext
    ) -> String {
        if candidates.count <= 1 {
            return candidates.first?.chat.title ?? "this chat"
        }

        let names = candidates.map(\.chat.title)
        let joinedNames = names.joined(separator: ", ")
        if let entity = summaryEntityName(from: queryContext) {
            return "recent chats involving \(entity): \(joinedNames)"
        }
        return "recent chats: \(joinedNames)"
    }

    func summaryScopeLabel(
        from candidates: [Candidate],
        queryContext: QueryContext
    ) -> String {
        if candidates.count <= 1 {
            return candidates.first?.chat.title ?? "Recent Context"
        }
        if let entity = summaryEntityName(from: queryContext) {
            return "Recent \(entity) Context"
        }
        return "Recent Context"
    }

    private func summaryEntityName(from queryContext: QueryContext) -> String? {
        guard !queryContext.senderFallbackTerms.isEmpty else { return nil }
        return queryContext.senderFallbackTerms
            .map { token in
                token
                    .split(separator: ".")
                    .map { part in part.prefix(1).uppercased() + part.dropFirst() }
                    .joined(separator: ".")
            }
            .joined(separator: " ")
    }

    private func expandedAnchorWindow(in messages: [TGMessage], anchorMessage: TGMessage?) -> [TGMessage] {
        let sorted = messages.sorted { $0.date < $1.date }
        guard let anchorMessage,
              let anchorIndex = sorted.firstIndex(where: { $0.id == anchorMessage.id }) else {
            return sorted
        }
        // ±10 around the anchor = 21-message window. Wider than the old
        // ±6 because the digest no longer re-ranks within the chat
        // (research consensus is chronological context beats top-K
        // relevance for chat summarization), so the AI's coherence
        // comes from seeing the surrounding conversation, not from
        // higher per-message density.
        let radius = 10
        let lowerBound = max(0, anchorIndex - radius)
        let upperBound = min(sorted.count - 1, anchorIndex + radius)
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
        let preferredRanked: [TGMessage]
        if queryContext.prefersImplicitRecentWindow {
            let substantiveOnly = ranked.filter(hasSubstantiveBodyText)
            preferredRanked = substantiveOnly.isEmpty ? ranked : substantiveOnly
        } else {
            preferredRanked = ranked
        }
        let selected = Array(preferredRanked.prefix(6)).sorted { $0.date < $1.date }
        return selected.isEmpty ? Array(messages.sorted { $0.date < $1.date }.suffix(AppConstants.Search.Summary.summaryMessageLimit)) : selected
    }

    func rankedSupportMessages(_ messages: [TGMessage], queryContext: QueryContext) -> [TGMessage] {
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
        let isSubstantive = hasSubstantiveBodyText(message)
        if text.count < 90 && shortLowSignalPrefixes.contains(where: { text.hasPrefix($0) }) {
            score -= 3.0
        }
        if queryContext.prefersImplicitRecentWindow && !isSubstantive {
            score -= 2.4
        }
        score += min(Double(text.count), 500) / 250.0
        if queryContext.prefersImplicitRecentWindow {
            score += recentFreshnessScore(for: message.date) * 2.0
        }
        return score
    }

    func recentFreshnessScore(for date: Date) -> Double {
        let lookback = TimeInterval(AppConstants.Search.Summary.implicitRecentRecapLookbackDays * 86_400)
        let age = max(0, Date().timeIntervalSince(date))
        let freshness = max(0, 1 - min(age, lookback) / lookback)
        return freshness
    }

    func isSummaryAnchor(text: String) -> Bool {
        [
            "summary", "overview", "bottom line", "full picture", "decided",
            "thought we", "main gaps", "feedback:", "team brief", "rankings",
            "compiled up here", "what we discussed", "in summary"
        ].contains(where: text.contains)
    }

    func applyTimeRange(_ hits: [LocalHit], timeRange: TimeRangeConstraint?) -> [LocalHit] {
        guard let timeRange else { return hits }
        return hits.filter { timeRange.contains($0.message.date) }
    }

    func applyTimeRange(_ messages: [TGMessage], timeRange: TimeRangeConstraint?) -> [TGMessage] {
        guard let timeRange else { return messages }
        return messages.filter { timeRange.contains($0.date) }
    }

    func snippet(from text: String) -> String {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return String(normalized.prefix(AppConstants.AI.SemanticSearch.messagePreviewCharacterLimit))
    }
}
