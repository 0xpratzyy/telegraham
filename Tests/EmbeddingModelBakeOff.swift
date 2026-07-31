//
//  EmbeddingModelBakeOff.swift
//  Pidgy — is the transformer embedding model worth its cost?
//
//  e5 (`multilingual-e5-small`) costs, measured on a live install
//  2026-07-26: ~2.2 GB heap + ~0.5 GB GPU surfaces while loaded, 25-40%
//  CPU for the length of an indexing pass. Published numbers say a STATIC
//  model reaches ~85-92% of its quality at ~125x the CPU speed in tens of
//  megabytes — but those are MTEB numbers on formal text. This corpus is
//  Hinglish, romanised Hindi and code-switched chat, which no public
//  benchmark covers, so the only honest way to choose is to measure here.
//
//  What it does: embeds the SAME local messages with the candidate model
//  under its own `modelVersion` (nothing live is touched — vectors are
//  namespaced by version), then scores both models on the labelled
//  topic-search oracle and prints them side by side.
//
//  Run:
//    TEST_RUNNER_PIDGY_RUN_BAKEOFF=1 xcodebuild test \
//      -project Pidgy.xcodeproj -scheme Pidgy -destination 'platform=macOS' \
//      -only-testing:PidgyTests/EmbeddingModelBakeOff
//

import XCTest
@testable import Pidgy

final class EmbeddingModelBakeOff: XCTestCase {

    private struct OracleEntry: Decodable {
        let id: String
        let query: String
        let expectedKind: String
        let expectedChatIds: [Int64]?
        /// exact-lookup oracles list several acceptable chats instead.
        let acceptableChatIds: [Int64]?

        var targets: Set<Int64> { Set((expectedChatIds ?? []) + (acceptableChatIds ?? [])) }
    }
    private struct Oracle: Decodable { let entries: [OracleEntry] }

    /// Every labelled set available, so the verdict rests on ~100 queries
    /// rather than 13. Kept as separate buckets because the task types are
    /// genuinely different — exact-lookup is FTS's home turf, topic search
    /// is where vectors are supposed to earn their place — and a model that
    /// only wins on one of them is a different decision from one that wins
    /// on all.
    private static let oracleFiles = [
        "topic_search_oracle_v1.json",
        "topic_search_oracle_v2.json",
        "summary_oracle_v3.json",
        "exact_lookup_oracle_v2.json"
    ]

    private static let e5Version = "e5-multilingual-small-v1"
    private static let staticVersion = "static-multilingual-v1"
    /// Enough corpus for the comparison to mean something without making a
    /// bake-off run take longer than the decision deserves.
    private static let messagesToEmbed = 4000
    private static let topN = 5

    func testStaticVersusTransformerEmbeddings() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PIDGY_RUN_BAKEOFF"] == "1",
            "Set PIDGY_RUN_BAKEOFF=1 to run the embedding bake-off."
        )
        let buckets = try Self.loadAllOracles()
        let entries = buckets.flatMap(\.entries)
        try XCTSkipIf(entries.isEmpty, "Oracles have no scorable entries.")

        // 1. Build the candidate's vector space over the same messages e5
        //    already covers, so the comparison is like-for-like.
        let e5Count = await VectorStore.shared.vectorCount(modelVersion: Self.e5Version)
        try XCTSkipIf(e5Count == 0, "No e5 vectors present — nothing to compare against.")
        let existingStatic = await VectorStore.shared.vectorCount(modelVersion: Self.staticVersion)

        let embedStart = Date()
        var embedded = existingStatic
        if existingStatic < min(e5Count, Self.messagesToEmbed) {
            embedded = await Self.buildCandidateVectors(limit: Self.messagesToEmbed)
        }
        let embedSeconds = Date().timeIntervalSince(embedStart)

        // 2. Score every configuration production could actually ship.
        //    Vector-only says which SPACE is better; the fused rows say
        //    whether the vectors add anything ON TOP OF FTS — which is the
        //    only question that decides the shipped design. This matters
        //    especially for the static model: it is a bag-of-words (no word
        //    order, no polysemy), so it may be re-deriving what FTS already
        //    knows rather than contributing new signal.
        var score: [String: (t1: Int, tN: Int)] = [:]
        func credit(_ key: String, _ ranked: [Int64], _ expected: Set<Int64>) -> Bool {
            var s = score[key] ?? (0, 0)
            if ranked.first.map(expected.contains) ?? false { s.t1 += 1 }
            let hitN = ranked.prefix(Self.topN).contains(where: expected.contains)
            if hitN { s.tN += 1 }
            score[key] = s
            return hitN
        }

        var lines: [String] = []
        for bucket in buckets {
            for entry in bucket.entries {
                let expected = entry.targets
                let fts = await Self.ftsScores(entry.query)
                let e5 = await Self.vectorScores(entry.query, version: Self.e5Version)
                let st = await Self.vectorScores(entry.query, version: Self.staticVersion)
                let ent = await Self.entityScores(entry.query)
                let bothVectors = Self.blend(Self.blend(fts, 0.6, e5, 0.2), 1.0, st, 0.2)

                for (key, ranked) in [
                    ("e5-only", Self.rank(e5)),
                    ("static-only", Self.rank(st)),
                    ("entity-only", Self.rank(ent)),
                    ("fts-only", Self.rank(fts)),
                    ("fts+e5", Self.rank(Self.blend(fts, 0.6, e5, 0.4))),
                    ("fts+static", Self.rank(Self.blend(fts, 0.6, st, 0.4))),
                    ("fts+both", Self.rank(bothVectors)),
                    // The three-signal fusion the research prescribes.
                    ("fts+entity", Self.rank(Self.blend(fts, 0.6, ent, 0.4))),
                    ("fts+both+entity", Self.rank(Self.blend(bothVectors, 1.0, ent, 0.3))),
                    ("fts+static+entity", Self.rank(Self.blend(Self.blend(fts, 0.6, st, 0.3), 1.0, ent, 0.3)))
                ] {
                    // Per-bucket AND overall, so a model that only wins on
                    // one task type can't hide inside the average.
                    _ = credit(key, ranked, expected)
                    _ = credit("\(bucket.name)|\(key)", ranked, expected)
                }
            }
            lines.append("\(bucket.name): \(bucket.entries.count) queries")
        }

        let n = entries.count
        func pct(_ x: Int, of total: Int) -> Int {
            total == 0 ? 0 : Int((Double(x) / Double(total) * 100).rounded())
        }
        func row(_ label: String, _ key: String, of total: Int = n) -> String {
            let s = score[key] ?? (0, 0)
            return "\(label.padding(toLength: 22, withPad: " ", startingAt: 0))\(pct(s.t1, of: total))%\t\(pct(s.tN, of: total))%"
        }
        let perBucket = buckets.map { bucket -> String in
            let total = bucket.entries.count
            return """
            \(bucket.name) (\(total) queries)          top-1\ttop-\(Self.topN)
            \(row("  fts only", "\(bucket.name)|fts-only", of: total))
            \(row("  fts + e5", "\(bucket.name)|fts+e5", of: total))
            \(row("  fts + static", "\(bucket.name)|fts+static", of: total))
            \(row("  fts + both + entity", "\(bucket.name)|fts+both+entity", of: total))
            """
        }.joined(separator: "\n\n")

        print("""

        ═════════════ EMBEDDING BAKE-OFF ═════════════
        \(lines.joined(separator: "\n"))
        ──────────────────────────────────────────────
        candidate vectors embedded this run: \(embedded) in \(String(format: "%.1f", embedSeconds))s
        queries: \(n)

        SIGNAL ALONE                top-1\ttop-\(Self.topN)
        \(row("e5 (transformer)", "e5-only"))
        \(row("static (bag-of-words)", "static-only"))
        \(row("entity (facts)", "entity-only"))

        WHAT SHIPS (fused w/ FTS)   top-1\ttop-\(Self.topN)
        \(row("fts only", "fts-only"))
        \(row("fts + e5", "fts+e5"))
        \(row("fts + static", "fts+static"))
        \(row("fts + both", "fts+both"))
        \(row("fts + entity", "fts+entity"))
        \(row("fts + static + entity", "fts+static+entity"))
        \(row("fts + both + entity", "fts+both+entity"))

        ── BY TASK TYPE ───────────────────────────────
        \(perBucket)

        → The fused rows decide it. A vector space that wins alone but adds
          nothing over FTS is redundant signal, not better retrieval.
        ══════════════════════════════════════════════

        """)
        XCTAssertGreaterThan(n, 0)
    }

    // MARK: - Helpers

    /// Embed local messages under the candidate's version. Reads the same
    /// searchable text the indexer uses so neither model gets a different
    /// corpus.
    private static func buildCandidateVectors(limit: Int) async -> Int {
        let messages = await DatabaseManager.shared.loadSearchableMessages(limit: limit)
        var stored = 0
        var batch: [VectorStore.EmbeddingRecord] = []
        for message in messages {
            guard let text = message.textContent, !text.isEmpty else { continue }
            guard let vector = await EmbeddingService.shared.embed(
                text: text, modelVersion: staticVersion, isQuery: false
            ) else { continue }
            batch.append(
                VectorStore.EmbeddingRecord(
                    messageId: message.id,
                    chatId: message.chatId,
                    vector: vector,
                    textPreview: String(text.prefix(120)),
                    modelVersion: staticVersion
                )
            )
            if batch.count >= 200 {
                await VectorStore.shared.storeBatch(batch)
                stored += batch.count
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty {
            await VectorStore.shared.storeBatch(batch)
            stored += batch.count
        }
        return stored
    }

    /// Best vector score per chat, for one model version.
    private static func vectorScores(_ query: String, version: String) async -> [Int64: Double] {
        guard let queryVector = await EmbeddingService.shared.embed(
            text: query, modelVersion: version, isQuery: true
        ) else { return [:] }
        let hits = await VectorStore.shared.search(
            query: queryVector,
            topK: AppConstants.AI.SemanticSearch.vectorTopMessages,
            modelVersion: version
        )
        var best: [Int64: Double] = [:]
        for hit in hits { best[hit.chatId] = max(best[hit.chatId] ?? 0, hit.score) }
        return best
    }

    /// Best normalized FTS score per chat, using production's graduated
    /// variant expressions so the lexical baseline is the real one.
    private static func ftsScores(_ query: String) async -> [Int64: Double] {
        var best: [Int64: Double] = [:]
        for expression in buildFTSVariants(rawQuery: query) {
            let hits = await DatabaseManager.shared.localSearchFTSRaw(
                rawFTSQuery: expression,
                limit: AppConstants.AI.SemanticSearch.ftsTopMessages
            )
            guard let top = hits.map(\.score).max(), top > 0 else { continue }
            for hit in hits {
                let normalized = hit.score / top
                best[hit.message.chatId] = max(best[hit.message.chatId] ?? 0, normalized)
            }
        }
        return best
    }

    /// THE MISSING THIRD SIGNAL. Current 2026 memory systems fuse semantic
    /// similarity + keyword + ENTITY matching; Pidgy ships only the first
    /// two. It already has the entity collection — `facts` is exactly that
    /// (subject_entity / object_text / action, FTS-indexed and weighted so
    /// the subject dominates) — and never consults it at retrieval time.
    ///
    /// Score = a chat's best-ranked matching fact, normalized. Facts are
    /// sparse and high-precision, so this is a BOOST for chats that are
    /// genuinely about the query's people and commitments, not a ranker on
    /// its own.
    private static func entityScores(_ query: String) async -> [Int64: Double] {
        let facts = await DatabaseManager.shared.searchFacts(query: query, limit: 40)
        guard !facts.isEmpty else { return [:] }
        // searchFacts returns best-first; rank position is the only signal
        // available, so decay it rather than inventing a similarity number.
        var best: [Int64: Double] = [:]
        for (index, fact) in facts.enumerated() {
            let score = 1.0 / (1.0 + Double(index) * 0.15)
            best[fact.sourceChatId] = max(best[fact.sourceChatId] ?? 0, score)
        }
        return best
    }

    private static func blend(
        _ a: [Int64: Double], _ aWeight: Double,
        _ b: [Int64: Double], _ bWeight: Double
    ) -> [Int64: Double] {
        var out: [Int64: Double] = [:]
        for (id, score) in a { out[id, default: 0] += score * aWeight }
        for (id, score) in b { out[id, default: 0] += score * bWeight }
        return out
    }

    private static func rank(_ scores: [Int64: Double]) -> [Int64] {
        scores.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
    }

    private struct Bucket { let name: String; let entries: [OracleEntry] }

    /// Load every oracle, keep only scorable hits, and drop duplicate
    /// queries across files so a repeated question can't count twice.
    private static func loadAllOracles() throws -> [Bucket] {
        guard let dir = repoRoot() else { throw XCTSkip("evals/ not found") }
        var seenQueries = Set<String>()
        var buckets: [Bucket] = []
        for file in oracleFiles {
            let url = dir.appendingPathComponent("evals/\(file)")
            guard let data = try? Data(contentsOf: url),
                  let oracle = try? JSONDecoder().decode(Oracle.self, from: data) else { continue }
            let scorable = oracle.entries.filter { entry in
                guard entry.expectedKind == "hit", !entry.targets.isEmpty else { return false }
                let key = entry.query.lowercased()
                guard !seenQueries.contains(key) else { return false }
                seenQueries.insert(key)
                return true
            }
            if !scorable.isEmpty {
                buckets.append(Bucket(name: file.replacingOccurrences(of: ".json", with: ""), entries: scorable))
            }
        }
        return buckets
    }

    private static func repoRoot() -> URL? {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("evals").path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}
