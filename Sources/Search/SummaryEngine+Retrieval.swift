import Foundation

extension SummaryEngine {
    struct PerChatDigest {
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
    func loadPerChatDigest(
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
    func applyRRF(
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

    func buildCandidates(
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
    func personAnchoredChats(
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
    func mergePersonAnchoredCandidates(
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

    func buildQueryContext(_ querySpec: QuerySpec) -> QueryContext {
        let rawQuery = querySpec.rawQuery
        let normalized = normalize(rawQuery)
        let queryTerms = Array(NSOrderedSet(array: normalized
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "@" && $0 != "." && $0 != "-" })
            .map { sanitizeQueryToken(String($0)) }
            .filter { token in
                !token.isEmpty
                    && !summaryStopWords.contains(token)
                    && !SearchStopWords.isFunctionWord(token)
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
                        && !SearchStopWords.isFunctionWord($0)
                        && $0.count >= 3
                }
            if !extracted.isEmpty {
                return Array(NSOrderedSet(array: extracted)) as? [String] ?? extracted
            }
        }
        return []
    }

    func focusTimeRange(
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

    private func sanitizeQueryToken(_ token: String) -> String {
        token.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
    }

    func searchableText(for message: TGMessage) -> String {
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

    func hasSubstantiveBodyText(_ message: TGMessage) -> Bool {
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
    func scopedSenderFallbackRanked(
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
