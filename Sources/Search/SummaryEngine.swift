import Foundation

@MainActor
final class SummaryEngine {
    static let shared = SummaryEngine()

    struct LocalHit {
        let message: TGMessage
        var ftsScore: Double
        var vectorScore: Double
    }

    struct MessageKey: Hashable {
        let chatId: Int64
        let messageId: Int64

        init(_ message: TGMessage) {
            chatId = message.chatId
            messageId = message.id
        }
    }

    struct QueryContext {
        let raw: String
        let normalized: String
        let queryTerms: [String]
        let scopedTerms: [String]
        let topicTerms: [String]
        let senderFallbackTerms: [String]
        let cluePhrases: [String]
        let requiresJointAnchor: Bool
        let requiresStrictPersonAnchors: Bool
        let prefersImplicitRecentWindow: Bool
        let retrievalQuery: String
    }

    struct Candidate {
        let chat: TGChat
        let bestMessage: TGMessage?
        let bestSnippet: String
        let score: Double
        let queryCoverage: Int
        let jointAnchorHits: Int
        let personAnchorHits: Int
        let topMessages: [TGMessage]
        /// True when this candidate was added because the user's query
        /// named a person and this chat matches that person, regardless
        /// of whether FTS/vector hit anything inside the chat. Per-chat
        /// digest treats these specially — recent-window slice instead
        /// of relevance-ranked picks — because the user usually wants
        /// "what's happening with X recently" not "messages about X".
        let isPersonAnchored: Bool
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
        let queryContext = buildQueryContext(querySpec)
        let retrievalQuery = queryContext.retrievalQuery.isEmpty ? querySpec.rawQuery : queryContext.retrievalQuery
        let effectiveTimeRange = focusTimeRange(explicitTimeRange: querySpec.timeRange, queryContext: queryContext)

        // Build graduated FTS variants and run them all in parallel
        // alongside vector search and the sender-name fallback. Each
        // returns its own ranked list — the previous flow ran a single
        // FTS query (forced AND-of-quoted-tokens) which is exactly why
        // "Bridge integration" returned zero on a corpus where
        // "bridge" and "integration" never appeared in the same message.
        async let variantHits = runFTSVariants(
            rawQuery: retrievalQuery,
            chatIds: scopedChatIds,
            limit: constants.ftsTopMessages,
            telegramService: telegramService
        )

        async let vectorHitsTask = telegramService.localVectorSearch(
            query: retrievalQuery,
            chatIds: scopedChatIds,
            limit: constants.vectorTopMessages
        )
        async let senderRankedTask = scopedSenderFallbackRanked(
            queryContext: queryContext,
            scopedChatIds: scopedChatIds,
            timeRange: effectiveTimeRange,
            fallbackLimit: constants.fallbackTopMessages,
            chatsById: chatById
        )

        let allFTSLists = await variantHits
        let vectorHits = await vectorHitsTask
        let senderHits = await senderRankedTask

        // RRF combine all sources — FTS variants + vector + sender — into
        // a single deduped ranked list. Items appearing in multiple lists
        // win because their per-list contributions sum.
        var rankedSources: [[TelegramService.LocalMessageSearchHit]] = allFTSLists
        rankedSources.append(vectorHits)
        rankedSources.append(senderHits)

        let merged = applyTimeRange(
            applyRRF(rankedLists: rankedSources),
            timeRange: effectiveTimeRange
        )
        let fts_candidates = buildCandidates(
            from: merged,
            chatsById: chatById,
            queryContext: queryContext,
            timeRange: effectiveTimeRange
        )
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.chat.order > rhs.chat.order
            }

        // Person-anchored injection. When the planner extracts a person
        // name from the query ("with Akhil"), surface that person's
        // chat as a guaranteed candidate — even when FTS/vector found
        // no hits on the topic terms inside that chat. Before this,
        // "what did we decide with Akhil on email" only included Akhil
        // B if its messages also FTS-matched "email", and most often
        // they didn't, so the most relevant chat was silently dropped
        // before reaching the AI.
        let plannerPeople = querySpec.plannerHints?.people ?? []
        let personAnchoredChats_ = personAnchoredChats(
            people: plannerPeople,
            visibleChats: scopedChats
        )
        let candidates = mergePersonAnchoredCandidates(
            existing: fts_candidates,
            personAnchoredChats: personAnchoredChats_
        )

          let supportingCandidates = Array(candidates.prefix(AppConstants.Search.Summary.supportingResultLimit))
          // Preliminary chips for the no-summary early-return paths below —
          // these use each candidate's raw best-search-hit. Once we actually
          // build a summary, the chips are rebuilt from the per-chat digest
          // so each chip's snippet matches what the AI actually saw.
          let preliminaryResults = supportingCandidates.enumerated().map { index, candidate in
              SemanticSearchResult(
                  chatId: candidate.chat.id,
                  chatTitle: candidate.chat.title,
                  reason: index == 0 ? "Best local summary context" : "Supporting local context",
                  relevance: index == 0 ? .high : .medium,
                  matchingMessages: [candidate.bestSnippet]
              )
          }

          guard let focus = supportingCandidates.first else {
              return SearchExecution(output: nil, results: preliminaryResults)
          }
          // No score floor: if the retrievers found any candidates, send
          // them to the AI. Real example that motivated dropping the
          // floor — "what did we decide with Akhil on email" surfaced
          // 6 candidate chats (Akhil B included, MEDIUM relevance), but
          // the focus-score gate (0.95) silently swallowed the summary
          // and the UI rendered "No clear local summary context found"
          // sitting on top of 6 visible search results. Worse, the gate
          // also caused empty hits on time-windowed queries that had
          // perfect FTS matches inside the window. The AI is a better
          // judge of "is this enough context to answer" than a static
          // numeric threshold — per the codebase rule, fix AI mistakes
          // in the prompt rather than pre-gating AI access with
          // heuristics.

        let summaryCandidates = summaryCandidates(
            from: supportingCandidates,
            focus: focus,
            queryContext: queryContext
        )
        // Per-chat digest — every participating chat gets its own slice of
        // top-ranked messages instead of being squashed into one global top-6
        // (which used to let a single noisy chat crowd everything else out).
        let perChatDigest = await loadPerChatDigest(
            for: summaryCandidates,
            timeRange: effectiveTimeRange,
            queryContext: queryContext,
            anchorMessage: summaryCandidates.count == 1 ? focus.bestMessage : nil
        )
        // Flatten preserving chat grouping (chat A's messages, then chat B's,
        // etc). SummaryPrompt.userMessage groups them under "=== Chat: name ==="
        // headers so the AI knows which message came from where.
        let boundedMessages = perChatDigest.flatMap { $0.messages }

        let summaryScopeDescription = summaryScopeDescription(
            from: summaryCandidates,
            queryContext: queryContext
        )
        let summaryScopeLabel = summaryScopeLabel(
            from: summaryCandidates,
            queryContext: queryContext
        )

        let summary = await summarize(
            query: querySpec.rawQuery,
            scopeDescription: summaryScopeDescription,
            perChatDigest: perChatDigest,
            aiService: aiService,
            fallbackSnippet: focus.bestSnippet,
            queryContext: queryContext
        )
        let summaryText = summary.text

        // Build the supporting-chat chips. When the AI returned real
        // extracts for some chats, show ONLY those — and use each
        // chat's extract as the chip snippet, so users see WHY the
        // chat is included (not a random "Hehe" last message). When
        // there are no extracts (AI off / all NOT_RELEVANT) we fall
        // back to the perChatDigest list with the original top-hit
        // snippet, so the user can still see what was looked at.
        let supportingResults: [SemanticSearchResult]
        if !summary.extracts.isEmpty {
            supportingResults = summary.extracts.enumerated().map { index, extract in
                SemanticSearchResult(
                    chatId: extract.chat.id,
                    chatTitle: extract.chat.title,
                    reason: index == 0 ? "Most relevant context" : "Supporting context",
                    relevance: index == 0 ? .high : .medium,
                    matchingMessages: [snippet(from: extract.text)]
                )
            }
        } else {
            supportingResults = perChatDigest.enumerated().map { index, digest in
                SemanticSearchResult(
                    chatId: digest.candidate.chat.id,
                    chatTitle: digest.candidate.chat.title,
                    reason: index == 0 ? "Best local summary context" : "Supporting local context",
                    relevance: index == 0 ? .high : .medium,
                    matchingMessages: [snippet(from: (digest.topRankedMessage ?? digest.candidate.bestMessage)?.displayText
                                              ?? digest.candidate.bestSnippet)]
                )
            }
        }

        // Prefer the AI-confirmed most-relevant chat as the click-
        // through target, so "open this chat" jumps to where the
        // answer actually lives — not the highest-FTS-scoring
        // candidate, which is often a noisy near-miss when the
        // retriever surfaced unrelated keyword hits.
        let supportingChatId = summary.extracts.first?.chat.id ?? focus.chat.id
        let output = SummarySearchOutput(
            summaryText: summaryText,
            title: summaryTitle(for: querySpec.rawQuery, scopeLabel: summaryScopeLabel),
            supportingChatId: supportingChatId,
            supportingMessageIds: boundedMessages.map(\.id)
        )

        return SearchExecution(output: output, results: supportingResults)
    }

    let summaryStopWords: Set<String> = [
        "what", "did", "we", "with", "the", "a", "an", "and", "or", "to", "of", "for",
        "me", "my", "our", "about", "give", "quick", "summary", "summarize", "summarise",
        "recap", "last", "last-week", "this-week", "week", "month", "from", "this", "that",
        "right", "now", "after", "latest", "recent", "context", "lately", "happened",
        "discuss", "discussed", "conclude", "concluded", "decide", "decided", "main", "gaps",
        "chat", "chats", "thread", "conversation", "are", "is", "was", "were"
    ]

    let shortLowSignalPrefixes = [
        "check ", "tell ", "digging into it", "hetzner se compare", "what's the context",
        "yoo", "whoop", "wispr", "lemme know"
    ]
}
