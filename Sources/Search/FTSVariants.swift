import Foundation

/// Common English filler that adds noise to FTS variants without
/// describing the topic the user is looking for. Pulled directly into
/// the variant builder because the FTS layer doesn't see the upstream
/// semantic-topic stop-word filter — without this, queries like
/// "what did sumedha say about invoicing" generate an OR variant that
/// matches every chat with the word "did" in it.
private let ftsVariantStopWords: Set<String> = [
    "a", "about", "after", "again", "all", "also", "an", "and", "any", "are", "around",
    "as", "at", "be", "been", "but", "by", "can", "could", "did", "do", "does", "doing",
    "done", "during", "each", "for", "from", "get", "give", "got", "had", "has", "have",
    "he", "her", "here", "him", "his", "how", "i", "if", "in", "into", "is", "it", "its",
    "just", "let", "like", "look", "make", "me", "more", "most", "my", "no", "not", "now",
    "of", "on", "one", "or", "our", "out", "over", "quick", "really", "say", "said",
    "see", "she", "should", "so", "some", "such", "tell", "than", "that", "the", "their",
    "them", "then", "there", "these", "they", "this", "those", "through", "to", "told",
    "too", "under", "up", "us", "use", "very", "want", "was", "we", "were", "what", "when",
    "where", "which", "while", "who", "why", "will", "with", "would", "you", "your",
    "yours", "summary", "summarize", "summarise", "recap", "update", "updates"
]

/// Build graduated FTS5 MATCH expressions from a free-text query so the
/// retrieval layer can run multiple ranked variants in parallel and fuse
/// them via RRF — instead of forcing a single AND-of-quoted-tokens shape
/// that returns zero whenever the user's terms never co-occur in the same
/// message (the "Bridge integration → 0 hits" failure mode).
///
/// For "Bridge integration" the variants emitted are:
///   - `NEAR("Bridge" "integration", 5)`  (strict phrase proximity)
///   - `"Bridge" "integration"`           (AND, both terms required)
///   - `"Bridge" OR "integration"`        (OR, either term)
///   - `Bridge* OR integration*`          (prefix-OR, catches stem variants)
///
/// For a single-token query, just exact + prefix is emitted.
/// Empty input yields an empty array — callers should treat that as
/// "no FTS to run" and fall back to vector / sender / title matching.
func buildFTSVariants(rawQuery: String) -> [String] {
    let rawTokens = rawQuery
        .replacingOccurrences(of: "\"", with: " ")
        .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" })
        .map(String.init)
        .filter { token in
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && trimmed.count >= 2
        }
    // Drop common English filler so the OR / prefix variants don't match
    // every chat that happens to contain "did" or "what". If every token
    // is a stop word (e.g. "tell me about this") fall back to using them
    // verbatim — better to over-match than to emit an empty variant set.
    let filtered = rawTokens.filter { !ftsVariantStopWords.contains($0.lowercased()) }
    let tokens = filtered.isEmpty ? rawTokens : filtered
    guard !tokens.isEmpty else { return [] }

    let quoted = tokens.map { "\"\($0)\"" }
    let prefixed = tokens.map { "\($0)*" }

    if tokens.count == 1 {
        return [quoted[0], prefixed[0]]
    }

    var variants: [String] = []
    variants.append("NEAR(\(quoted.joined(separator: " ")), 5)")
    variants.append(quoted.joined(separator: " "))
    variants.append(quoted.joined(separator: " OR "))
    variants.append(prefixed.joined(separator: " OR "))
    return variants
}

/// Run the graduated FTS variants in parallel against the local index
/// and return one ranked `[LocalMessageSearchHit]` list per variant
/// (preserving variant order). Empty result if the query produces no
/// variants. Each list is independently bm25-ranked by FTS5; combine via
/// RRF in the caller.
@MainActor
func runFTSVariants(
    rawQuery: String,
    chatIds: [Int64]?,
    limit: Int,
    telegramService: TelegramService
) async -> [[TelegramService.LocalMessageSearchHit]] {
    let variants = buildFTSVariants(rawQuery: rawQuery)
    guard !variants.isEmpty else { return [] }
    let capturedChatIds = chatIds
    return await withTaskGroup(
        of: (Int, [TelegramService.LocalMessageSearchHit]).self
    ) { group in
        for (index, expression) in variants.enumerated() {
            group.addTask {
                let hits = await telegramService.localFTSRawSearch(
                    rawFTSQuery: expression,
                    chatIds: capturedChatIds,
                    limit: limit
                )
                return (index, hits)
            }
        }
        var collected: [(Int, [TelegramService.LocalMessageSearchHit])] = []
        for await result in group { collected.append(result) }
        return collected.sorted { $0.0 < $1.0 }.map(\.1)
    }
}

/// Convenience wrapper for callers that take a single ranked FTS list:
/// runs the graduated variants and fuses them via RRF into one
/// deduped, score-sorted `[LocalMessageSearchHit]`. Items that appear
/// in multiple variants (e.g. NEAR + AND + OR) accumulate
/// contributions and rank above single-variant matches.
@MainActor
func runFTSVariantsFused(
    rawQuery: String,
    chatIds: [Int64]?,
    limit: Int,
    telegramService: TelegramService
) async -> [TelegramService.LocalMessageSearchHit] {
    let lists = await runFTSVariants(
        rawQuery: rawQuery,
        chatIds: chatIds,
        limit: limit,
        telegramService: telegramService
    )
    guard !lists.isEmpty else { return [] }

    let k: Double = 60
    var scoreByKey: [String: Double] = [:]
    var hitByKey: [String: TelegramService.LocalMessageSearchHit] = [:]
    for list in lists {
        for (rank, hit) in list.enumerated() {
            let key = "\(hit.message.chatId):\(hit.message.id)"
            scoreByKey[key, default: 0] += 1.0 / (k + Double(rank))
            if hitByKey[key] == nil { hitByKey[key] = hit }
        }
    }

    return scoreByKey
        .sorted { $0.value > $1.value }
        .prefix(limit)
        .compactMap { entry -> TelegramService.LocalMessageSearchHit? in
            guard let hit = hitByKey[entry.key] else { return nil }
            return TelegramService.LocalMessageSearchHit(message: hit.message, score: entry.value)
        }
}
