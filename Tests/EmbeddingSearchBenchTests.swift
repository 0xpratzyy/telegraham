import XCTest
@testable import Pidgy

/// Manual A/B benchmark for embedding-model quality — NOT a CI test.
///
/// Runs the topic-search oracle queries through the real VectorStore
/// against the developer's REAL local database and reports hit@1 /
/// hit@5 per query (a hit = any expected chat id appears in the top-k
/// vector results). Run once before an embedding-model upgrade and once
/// after the re-embed backfill completes; the delta is the model's
/// contribution, independent of oracle age (same corpus, same gold,
/// same day).
///
/// Gated behind PIDGY_EMBEDDING_BENCH=1 so CI (which has no real DB)
/// auto-skips. Note: opening the real DB applies any pending migrations
/// to it — the same migrations the app would apply on next launch.
///
///     PIDGY_EMBEDDING_BENCH=1 xcodebuild ... \
///       -only-testing:PidgyTests/EmbeddingSearchBenchTests test
final class EmbeddingSearchBenchTests: XCTestCase {
    private struct OracleEntry: Decodable {
        let id: String
        let query: String
        let expectedKind: String
        let expectedChatIds: [Int64]?
    }

    private struct Oracle: Decodable {
        let name: String
        let entries: [OracleEntry]
    }

    func testEmbeddingSearchBenchAgainstRealDatabase() async throws {
        guard ProcessInfo.processInfo.environment["PIDGY_EMBEDDING_BENCH"] == "1" else {
            throw XCTSkip("Manual benchmark — run with PIDGY_EMBEDDING_BENCH=1 against the real local DB")
        }

        let realDB = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pidgy/pidgy.db")
        guard FileManager.default.fileExists(atPath: realDB.path) else {
            throw XCTSkip("No real Pidgy database on this machine")
        }
        await DatabaseManager.shared.close()
        await DatabaseManager.shared.configureForTesting(
            databaseURLOverride: realDB,
            appSupportDirectoryOverride: nil
        )

        let oracleURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("evals/topic_search_oracle_v2.json")
        let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: oracleURL))
        let hitEntries = oracle.entries.filter { $0.expectedKind == "hit" && !($0.expectedChatIds ?? []).isEmpty }

        let activeVersion = await EmbeddingService.shared.activeModelVersion
        let activeCount = await VectorStore.shared.vectorCount(modelVersion: activeVersion)
        let legacyCount = await VectorStore.shared.vectorCount(modelVersion: EmbeddingService.legacyModelVersion)
        print("BENCH model=\(activeVersion) vectors(active)=\(activeCount) vectors(legacy)=\(legacyCount) queries=\(hitEntries.count)")

        var hit1 = 0
        var hit5 = 0
        for entry in hitEntries {
            let expected = Set(entry.expectedChatIds ?? [])
            let results = await VectorStore.shared.searchText(entry.query, topK: 25)
            let topChats = results.map(\.chatId)
            let inTop1 = topChats.first.map(expected.contains) ?? false
            let inTop5 = topChats.prefix(5).contains(where: expected.contains)
            if inTop1 { hit1 += 1 }
            if inTop5 { hit5 += 1 }
            print("BENCH \(entry.id) top1=\(inTop1 ? "Y" : "n") top5=\(inTop5 ? "Y" : "n") :: \(entry.query)")
        }

        let total = max(1, hitEntries.count)
        print(String(
            format: "BENCH SUMMARY model=%@ hit@1=%.0f%% (%d/%d) hit@5=%.0f%% (%d/%d)",
            activeVersion,
            100.0 * Double(hit1) / Double(total), hit1, total,
            100.0 * Double(hit5) / Double(total), hit5, total
        ))

        // Leave the singleton pointed away from the real DB for any
        // tests that might run after this one.
        await DatabaseManager.shared.close()
        await DatabaseManager.shared.configureForTesting(
            databaseURLOverride: nil,
            appSupportDirectoryOverride: nil
        )
    }
}
