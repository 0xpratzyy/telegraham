import Foundation

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
    let tokens = rawQuery
        .replacingOccurrences(of: "\"", with: " ")
        .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" })
        .map(String.init)
        .filter { token in
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && trimmed.count >= 2
        }
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
