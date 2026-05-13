import Foundation

@MainActor
final class SummaryEngine {
    static let shared = SummaryEngine()

    private struct LocalHit {
        let message: TGMessage
        var ftsScore: Double
        var vectorScore: Double
    }

    private struct MessageKey: Hashable {
        let chatId: Int64
        let messageId: Int64

        init(_ message: TGMessage) {
            chatId = message.chatId
            messageId = message.id
        }
    }

    private struct QueryContext {
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

    private struct Candidate {
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

    private struct PerChatDigest {
        let candidate: Candidate
        /// Messages sent to the AI for this chat, in chronological order.
        let messages: [TGMessage]
        /// The single message with the highest support score for this chat.
        /// Used as the supporting-chip preview so the chip text reflects
        /// the same line that drove the AI's view of this chat (instead of
        /// the raw FTS best-hit, which can be a totally different line).
        let topRankedMessage: TGMessage?
    }

    /// Build the per-chat context that goes to the AI. Each candidate
    /// contributes a CHRONOLOGICAL window of messages — not the old
    /// top-K-by-query-relevance slice. The win:
    ///
    /// - Per the research consensus (Glean, Slack AI, multi-doc
    ///   summarization papers), chat meaning is positional. Sending the
    ///   AI 5 relevance-shuffled messages scattered across a year of
    ///   chat history starves it of conversational flow. ±10 around the
    ///   anchor (or the 20 most-recent for person-anchored chats) lets
    ///   the model see the lead-up and the resolution.
    /// - The AI is a better filter than `rankedSupportMessages`. Giving
    ///   it more raw context and letting it pick relevance in-prompt
    ///   produces better summaries than pre-filtering with a static
    ///   scorer.
    ///
    /// Anchor selection per candidate:
    /// - Person-anchored chats (planner extracted a person name and
    ///   this chat matches) → no anchor, take the 20 most-recent
    ///   messages. The user wants "what's been happening lately with
    ///   X", not "X mentions of the topic terms".
    /// - Focus chat (first in list) → caller-supplied anchor if any,
    ///   else this chat's own bestMessage.
    /// - Other candidates → their own bestMessage as the anchor.
    private func loadPerChatDigest(
        for candidates: [Candidate],
        timeRange: TimeRangeConstraint?,
        queryContext: QueryContext,
        anchorMessage: TGMessage?
    ) async -> [PerChatDigest] {
        let perChatLimit = AppConstants.Search.Summary.perChatDigestMessageLimit
        var digests: [PerChatDigest] = []
        for (index, candidate) in candidates.enumerated() {
            let effectiveAnchor: TGMessage?
            if candidate.isPersonAnchored {
                effectiveAnchor = nil
            } else if index == 0 {
                effectiveAnchor = anchorMessage ?? candidate.bestMessage
            } else {
                effectiveAnchor = candidate.bestMessage
            }
            let messages = await loadSummaryMessages(
                for: candidate.chat,
                anchorMessage: effectiveAnchor,
                timeRange: timeRange
            )
            // `loadSummaryMessages` returns either an ascending-date
            // anchor window (±10 around the anchor) or an ascending-
            // date recent slice (when anchor is nil). For person-
            // anchored chats we want the most-recent end of the slice
            // — `suffix(N)` does the right thing for both shapes.
            let trimmed = Array(messages.suffix(perChatLimit))
            guard !trimmed.isEmpty else { continue }
            // Chip preview: prefer the originally surfaced
            // best-message (so the chip snippet matches what
            // triggered this chat to be a candidate), else the most
            // recent message in the window.
            let preview: TGMessage?
            if let bestMessage = candidate.bestMessage,
               trimmed.contains(where: { $0.id == bestMessage.id }) {
                preview = bestMessage
            } else {
                preview = trimmed.last
            }
            digests.append(PerChatDigest(
                candidate: candidate,
                messages: trimmed,
                topRankedMessage: preview
            ))
        }
        return digests
    }

    /// Reciprocal Rank Fusion (Cormack et al.). Combines many ranked
    /// lists into one without trying to compare absolute scores across
    /// retrievers. For each item, sum `1/(k + rank_i)` across every
    /// list it appears in. k=60 is the constant the original paper used
    /// and the default everywhere from Elasticsearch to Weaviate.
    ///
    /// We feed it: graduated FTS variants (phrase / AND / OR / prefix) +
    /// vector hits + sender-name fallback hits. Each is its own ranked
    /// list. Items that appear near the top of MULTIPLE lists win — so
    /// a message that strict-phrase-matches AND vector-matches outranks
    /// one that only OR-matches. Items appearing in just one list still
    /// get scored, but lose to multi-list contenders.
    ///
    /// Output uses the engine's existing `LocalHit` shape: the RRF
    /// score lands in `ftsScore` so downstream `buildCandidates` math
    /// keeps working. `vectorScore` is set to 0 because RRF already
    /// folded vector signal into the same field — the legacy weighted
    /// blend in buildCandidates becomes a no-op multiplier on 0 for
    /// the vector half.
    private func applyRRF(
        rankedLists: [[TelegramService.LocalMessageSearchHit]],
        k: Double = 60
    ) -> [LocalHit] {
        var byKey: [MessageKey: LocalHit] = [:]
        for list in rankedLists {
            for (rank, hit) in list.enumerated() {
                let key = MessageKey(hit.message)
                let contribution = 1.0 / (k + Double(rank))
                if var existing = byKey[key] {
                    existing.ftsScore += contribution
                    byKey[key] = existing
                } else {
                    byKey[key] = LocalHit(
                        message: hit.message,
                        ftsScore: contribution,
                        vectorScore: 0
                    )
                }
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
            let matchedSenderAnchorTerms: Set<String>
            let matchedTitleAnchorTerms: Set<String>
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
            // Down-weight chats that are obviously automated (Telegram
            // service notifications at chat 777000, bot account chats whose
            // names end with "Bot", etc.). Otherwise a single login or
            // verification message containing the keyword can become the
            // focus chat and drown out the real human conversations.
            let automatedPenalty: Double = isLikelyAutomatedChat(chat) ? 0.4 : 1.0
            let baseScore = (
                (hit.ftsScore * AppConstants.AI.SemanticSearch.ftsWeight) +
                (hit.vectorScore * AppConstants.AI.SemanticSearch.vectorWeight) +
                (chat.chatType.isPrivate ? 0.08 : 0)
            ) * automatedPenalty

            let normalizedText = normalize(searchableText(for: hit.message))
            let normalizedSender = normalize(hit.message.senderName ?? "")
            let normalizedTitle = normalize(chat.title)
            // Pidgy users often spell contact names playfully — "Deeeeeksha"
            // for Deeksha, "Akhilll" for Akhil, etc. The strict substring
            // check fails on those because "deeksha" isn't actually inside
            // "deeeeksha". Collapse repeating letters so people-name anchors
            // survive that kind of variation.
            let collapsedSender = collapseRepeatedLetters(normalizedSender)
            let collapsedTitle = collapseRepeatedLetters(normalizedTitle)
            let matchedQueryTerms = Set(queryContext.queryTerms.filter { normalizedText.contains($0) })
            let matchedScopedTerms = Set(queryContext.scopedTerms.filter {
                normalizedText.contains($0) || normalizedTitle.contains($0)
            })
            let matchedSenderAnchorTerms = Set(queryContext.senderFallbackTerms.filter { term in
                let collapsedTerm = collapseRepeatedLetters(term)
                return normalizedSender.contains(term) || collapsedSender.contains(collapsedTerm)
            })
            let matchedTitleAnchorTerms = Set(queryContext.senderFallbackTerms.filter { term in
                let collapsedTerm = collapseRepeatedLetters(term)
                return normalizedTitle.contains(term) || collapsedTitle.contains(collapsedTerm)
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
                matchedSenderAnchorTerms: matchedSenderAnchorTerms,
                matchedTitleAnchorTerms: matchedTitleAnchorTerms,
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
            let senderAnchorHits = sortedHits.filter { !$0.matchedSenderAnchorTerms.isEmpty }.count
            let titleAnchorHits = sortedHits.filter { !$0.matchedTitleAnchorTerms.isEmpty }.count
            let recentSenderAnchorHits = sortedHits.filter {
                $0.inTimeRange && !$0.matchedSenderAnchorTerms.isEmpty
            }.count
            let recentLowSignalAnchorHits = sortedHits.filter {
                $0.inTimeRange
                    && !$0.hasSubstantiveBodyText
                    && (!$0.matchedSenderAnchorTerms.isEmpty || !$0.matchedTitleAnchorTerms.isEmpty)
            }.count
            let recentSubstantiveAnchorHits = sortedHits.filter {
                $0.inTimeRange
                    && $0.hasSubstantiveBodyText
                    && (!$0.matchedSenderAnchorTerms.isEmpty || !$0.matchedTitleAnchorTerms.isEmpty)
            }.count
            let mostRecentSubstantiveAnchorDate = sortedHits
                .filter {
                    $0.inTimeRange
                        && $0.hasSubstantiveBodyText
                        && (!$0.matchedSenderAnchorTerms.isEmpty || !$0.matchedTitleAnchorTerms.isEmpty)
                }
                .map(\.hit.message.date)
                .max()
            let unanchoredScopedMentions = sortedHits.filter {
                !$0.matchedScopedTerms.isEmpty
                    && $0.matchedSenderAnchorTerms.isEmpty
                    && $0.matchedTitleAnchorTerms.isEmpty
            }.count
            let titleMatches = sortedHits.map(\.titleMatches).max() ?? 0
            let hasRecentBestHit = timeRange?.contains(best.hit.message.date) ?? false
            let hasRecentChatActivity = chat.lastActivityDate.map { timeRange?.contains($0) ?? false } ?? false

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
            aggregate += Double(min(senderAnchorHits, 3)) * 1.5
            aggregate += Double(min(titleAnchorHits, 2)) * 1.1
            aggregate += Double(min(recentSenderAnchorHits, 3)) * 0.45
            aggregate += Double(min(recentSubstantiveAnchorHits, 3)) * 1.45
            aggregate += Double(titleMatches) * 0.95
            if chat.chatType.isPrivate { aggregate += 0.08 }
            if queryContext.prefersImplicitRecentWindow {
                if hasRecentBestHit {
                    aggregate += AppConstants.Search.Summary.implicitRecentRecapBestHitBonus
                }
                if hasRecentChatActivity {
                    aggregate += AppConstants.Search.Summary.implicitRecentRecapChatActivityBonus
                } else {
                    aggregate -= AppConstants.Search.Summary.implicitRecentRecapMissingPenalty
                }
                if inRangeHits == 0 {
                    aggregate -= AppConstants.Search.Summary.implicitRecentRecapMissingPenalty
                }
                if let mostRecentSubstantiveAnchorDate {
                    aggregate += recentFreshnessScore(for: mostRecentSubstantiveAnchorDate) * 2.0
                }
                if recentSubstantiveAnchorHits == 0 && recentSenderAnchorHits > 0 {
                    aggregate -= 3.8
                }
            }
            if !queryContext.senderFallbackTerms.isEmpty && senderAnchorHits == 0 && titleAnchorHits == 0 {
                aggregate -= 3.6
            }
            if queryContext.requiresStrictPersonAnchors && senderAnchorHits == 0 && titleAnchorHits == 0 {
                aggregate -= 4.8
            }
            aggregate -= Double(unanchoredScopedMentions) * 0.35
            aggregate -= Double(min(recentLowSignalAnchorHits, 4)) * 0.95

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
                personAnchorHits: senderAnchorHits + titleAnchorHits,
                topMessages: Array(sortedHits.prefix(8).map(\.hit.message)),
                isPersonAnchored: false
            )
        }
    }

    /// Find visible chats whose title matches any of the named people
    /// extracted by the query planner. Used to inject "with Akhil"
    /// queries' chats as guaranteed candidates even when FTS/vector
    /// found nothing about the topic terms inside those chats.
    ///
    /// Match shape: a chat is included if any of its title tokens
    /// exactly equals the person name (case-insensitive), OR if the
    /// title token's collapsed-letters form equals the person name
    /// (so "Akhillll" → "akhil" matches a planner person "akhil").
    /// Token-equality (not prefix) avoids false positives like
    /// "Akhilesh" matching "akhil".
    private func personAnchoredChats(
        people: [String],
        visibleChats: [TGChat]
    ) -> [TGChat] {
        guard !people.isEmpty else { return [] }
        let normalizedPeople = Set(people.map { $0.lowercased() })
        var matched: [Int64: TGChat] = [:]
        for chat in visibleChats {
            let titleTokens = chat.title
                .lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
            let isMatch = titleTokens.contains { token in
                if normalizedPeople.contains(token) { return true }
                let collapsed = collapseRepeatedLetters(token)
                return normalizedPeople.contains(collapsed)
            }
            if isMatch {
                matched[chat.id] = chat
            }
        }
        return Array(matched.values).sorted { lhs, rhs in
            (lhs.lastMessage?.date ?? .distantPast)
                > (rhs.lastMessage?.date ?? .distantPast)
        }
    }

    /// Merge person-anchored chats into the existing candidates list.
    /// Chats already in `candidates` get their `isPersonAnchored` flag
    /// flipped (so the digest stage uses recent-window). Chats not
    /// already present become new candidates anchored on their last
    /// message and inserted at the front of the list.
    private func mergePersonAnchoredCandidates(
        existing candidates: [Candidate],
        personAnchoredChats chats: [TGChat]
    ) -> [Candidate] {
        guard !chats.isEmpty else { return candidates }
        var byId: [Int64: Candidate] = Dictionary(
            uniqueKeysWithValues: candidates.map { ($0.chat.id, $0) }
        )
        var prependOrder: [Int64] = []
        for chat in chats {
            if let existing = byId[chat.id] {
                byId[chat.id] = Candidate(
                    chat: existing.chat,
                    bestMessage: existing.bestMessage,
                    bestSnippet: existing.bestSnippet,
                    score: existing.score,
                    queryCoverage: existing.queryCoverage,
                    jointAnchorHits: existing.jointAnchorHits,
                    personAnchorHits: existing.personAnchorHits,
                    topMessages: existing.topMessages,
                    isPersonAnchored: true
                )
            } else {
                let synthetic = Candidate(
                    chat: chat,
                    bestMessage: chat.lastMessage,
                    bestSnippet: snippet(
                        from: chat.lastMessage?.displayText ?? ""
                    ),
                    // Moderate score — sorts above empty-keyword chats
                    // but doesn't beat strong FTS hits. The
                    // person-anchored flag is what guarantees inclusion;
                    // score only matters for ordering within the list.
                    score: 1.0,
                    queryCoverage: 0,
                    jointAnchorHits: 0,
                    personAnchorHits: 1,
                    topMessages: chat.lastMessage.map { [$0] } ?? [],
                    isPersonAnchored: true
                )
                byId[chat.id] = synthetic
                prependOrder.append(chat.id)
            }
        }
        // Order: synthetic person-anchored chats first (most recently
        // active first, per `chats` ordering), then everything else by
        // its existing rank.
        var merged: [Candidate] = []
        for chatId in prependOrder {
            if let c = byId[chatId] { merged.append(c) }
        }
        for candidate in candidates {
            if let c = byId[candidate.chat.id],
               !prependOrder.contains(candidate.chat.id) {
                merged.append(c)
            }
        }
        return merged
    }

    /// Result of map-reduce summarization. Caller needs both the final
    /// synthesized text AND the list of per-chat extracts so it can
    /// render chips for *only* the chats the AI found relevant —
    /// instead of showing every retrieval candidate with a random
    /// last-message snippet next to it.
    private struct SummarizeResult {
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
    private func summarize(
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

    private func loadSummaryMessages(
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

    private func mergeSummarySources(cached: [TGMessage], local: [TGMessage]) -> [TGMessage] {
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

    private func summaryTitle(for query: String, scopeLabel: String) -> String {
        if query.lowercased().contains("what did we decide") {
            return "Decision Summary"
        }
        return "Summary for \(scopeLabel)"
    }

    private func normalize(score: Double, maxScore: Double) -> Double {
        guard maxScore > 0 else { return 0 }
        return min(1, max(0, score / maxScore))
    }

    /// Collapses runs of the same letter into one ("deeeeksha" -> "deksha",
    /// "akhilll" -> "akhil"). Used as a cheap fuzzy-match for people-name
    /// anchors so playful spellings still align with the canonical name
    /// the user typed in their query.
    private func collapseRepeatedLetters(_ text: String) -> String {
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

    private func normalize(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func buildQueryContext(_ querySpec: QuerySpec) -> QueryContext {
        let rawQuery = querySpec.rawQuery
        let normalized = normalize(rawQuery)
        let queryTerms = Array(NSOrderedSet(array: normalized
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "@" && $0 != "." && $0 != "-" })
            .map { sanitizeQueryToken(String($0)) }
            .filter { token in
                !token.isEmpty
                    && !summaryStopWords.contains(token)
                    && token.count >= 3
            })) as? [String] ?? []
        let plannedPeople = querySpec.plannerHints?.people ?? []
        let scopedTerms = plannedPeople.isEmpty ? extractScopedTerms(from: normalized) : plannedPeople
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
        let plannedTopics = querySpec.plannerHints?.topicTerms ?? []
        let topicTerms = plannedTopics.isEmpty
            ? queryTerms.filter {
                !scopedTerms.contains($0) && !genericSummaryTokens.contains($0)
            }
            : plannedTopics
        let senderFallbackTerms: [String]
        if scopedTerms.count == 1 && topicTerms.isEmpty {
            senderFallbackTerms = scopedTerms
        } else if scopedTerms.isEmpty && topicTerms.count == 1 && queryTerms.count <= 3 {
            senderFallbackTerms = topicTerms
        } else {
            senderFallbackTerms = []
        }
        let prefersImplicitRecentWindow = !senderFallbackTerms.isEmpty
        return QueryContext(
            raw: rawQuery,
            normalized: normalized,
            queryTerms: queryTerms,
            scopedTerms: scopedTerms,
            topicTerms: topicTerms,
            senderFallbackTerms: senderFallbackTerms,
            cluePhrases: cluePhrases,
            requiresJointAnchor: !scopedTerms.isEmpty && !topicTerms.isEmpty,
            requiresStrictPersonAnchors: !plannedPeople.isEmpty,
            prefersImplicitRecentWindow: prefersImplicitRecentWindow,
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
        buildQueryContext(
            QuerySpec(
                rawQuery: rawQuery,
                mode: .summarySearch,
                family: .summary,
                preferredEngine: .summarize,
                scope: .all,
                scopeWasExplicit: false,
                replyConstraint: .none,
                timeRange: nil,
                parseConfidence: 1,
                unsupportedFragments: []
            )
        ).retrievalQuery
    }

    func retrievalQueryForTesting(_ querySpec: QuerySpec) -> String {
        buildQueryContext(querySpec).retrievalQuery
    }

    func mergedSummaryMessagesForTesting(cached: [TGMessage], local: [TGMessage]) -> [TGMessage] {
        mergeSummarySources(cached: cached, local: local)
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
                .map { sanitizeQueryToken(String($0)) }
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

    private func focusTimeRange(
        explicitTimeRange: TimeRangeConstraint?,
        queryContext: QueryContext
    ) -> TimeRangeConstraint? {
        if let explicitTimeRange {
            return explicitTimeRange
        }

        guard queryContext.prefersImplicitRecentWindow else { return nil }
        let now = Date()
        let lookback = TimeInterval(AppConstants.Search.Summary.implicitRecentRecapLookbackDays * 86_400)
        return TimeRangeConstraint(
            startDate: now.addingTimeInterval(-lookback),
            endDate: now,
            label: "Recent Context"
        )
    }

    private func summaryCandidates(
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

    private func summaryScopeDescription(
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

    private func summaryScopeLabel(
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

    private func recentFreshnessScore(for date: Date) -> Double {
        let lookback = TimeInterval(AppConstants.Search.Summary.implicitRecentRecapLookbackDays * 86_400)
        let age = max(0, Date().timeIntervalSince(date))
        let freshness = max(0, 1 - min(age, lookback) / lookback)
        return freshness
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
        "recap", "last", "last-week", "this-week", "week", "month", "from", "this", "that",
        "right", "now", "after", "latest", "recent", "context", "lately", "happened",
        "discuss", "discussed", "conclude", "concluded", "decide", "decided", "main", "gaps",
        "chat", "chats", "thread", "conversation", "are", "is", "was", "were"
    ]

    private let shortLowSignalPrefixes = [
        "check ", "tell ", "digging into it", "hetzner se compare", "what's the context",
        "yoo", "whoop", "wispr", "lemme know"
    ]

    private func sanitizeQueryToken(_ token: String) -> String {
        token.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
    }

    private func searchableText(for message: TGMessage) -> String {
        [message.senderName, message.displayText]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    /// Best-effort detection of automated chats (bots, Telegram service
    /// notifications, etc.) that shouldn't dominate summary scoring. Real
    /// bot detection requires a TelegramService roundtrip to fetch user
    /// metadata; here we use cheap title heuristics and a hardcoded id for
    /// the well-known Telegram service chat.
    private func isLikelyAutomatedChat(_ chat: TGChat) -> Bool {
        // Telegram's own service-notifications chat (the "Telegram" entry
        // that sends login codes, device alerts, etc.).
        if chat.id == 777_000 { return true }

        let normalizedTitle = chat.title.lowercased()
        // Account names ending in "bot" — Telegram convention for bots.
        if normalizedTitle.hasSuffix("bot") || normalizedTitle.hasSuffix(" bot") {
            return true
        }
        // Chats explicitly named "Telegram" without further context — the
        // app's own service chat surfaces that way for some accounts.
        if normalizedTitle == "telegram" { return true }
        return false
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
        guard !queryContext.senderFallbackTerms.isEmpty else {
            return []
        }

        let records = await DatabaseManager.shared.loadMessagesMatchingSenderTerms(
            chatIds: scopedChatIds,
            senderTerms: queryContext.senderFallbackTerms,
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

    /// Same data as `scopedSenderFallbackHits` but emitted as the public
    /// `LocalMessageSearchHit` shape, ordered most-recent-first so RRF
    /// gives the freshest sender match the highest rank contribution.
    /// Used by the new graduated-FTS + RRF retrieval flow which fuses
    /// multiple ranked lists uniformly — the legacy `LocalHit` flat-score
    /// path is kept for callers that haven't moved to RRF yet.
    private func scopedSenderFallbackRanked(
        queryContext: QueryContext,
        scopedChatIds: [Int64],
        timeRange: TimeRangeConstraint?,
        fallbackLimit: Int,
        chatsById: [Int64: TGChat]
    ) async -> [TelegramService.LocalMessageSearchHit] {
        guard !queryContext.senderFallbackTerms.isEmpty else {
            return []
        }

        let records = await DatabaseManager.shared.loadMessagesMatchingSenderTerms(
            chatIds: scopedChatIds,
            senderTerms: queryContext.senderFallbackTerms,
            startDate: timeRange?.startDate,
            endDate: timeRange?.endDate,
            limit: fallbackLimit
        )

        return records
            .sorted { $0.date > $1.date }
            .map { record in
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
                return TelegramService.LocalMessageSearchHit(message: message, score: 1.0)
            }
    }
}
