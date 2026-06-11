import Foundation
import GRDB

actor VectorStore {
    static let shared = VectorStore()

    struct SearchResult: Sendable, Equatable {
        let messageId: Int64
        let chatId: Int64
        let score: Double
    }

    struct EmbeddingRecord: Sendable {
        let messageId: Int64
        let chatId: Int64
        let vector: [Double]
        let textPreview: String
        /// Which model produced `vector`. Vectors from different models
        /// live in incomparable spaces; search filters to one version.
        let modelVersion: String
    }

    func store(
        messageId: Int64,
        chatId: Int64,
        vector: [Double],
        textPreview: String,
        modelVersion: String
    ) async {
        await storeBatch([
            EmbeddingRecord(
                messageId: messageId,
                chatId: chatId,
                vector: vector,
                textPreview: textPreview,
                modelVersion: modelVersion
            )
        ])
    }

    func storeBatch(_ records: [EmbeddingRecord]) async {
        guard !records.isEmpty else { return }

        do {
            try await storeBatchThrowing(records)
        } catch {
            print("[VectorStore] Failed to store embedding batch: \(error)")
        }
    }

    func storeBatchThrowing(_ records: [EmbeddingRecord]) async throws {
        guard !records.isEmpty else { return }

        try await DatabaseManager.shared.write { db in
            for record in records {
                try db.execute(
                    sql: """
                        INSERT INTO embeddings (message_id, chat_id, vector, text_preview, model_version)
                        VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(message_id, chat_id) DO UPDATE SET
                            vector = excluded.vector,
                            text_preview = excluded.text_preview,
                            model_version = excluded.model_version
                        """,
                    arguments: [
                        record.messageId,
                        record.chatId,
                        Self.encode(record.vector),
                        record.textPreview,
                        record.modelVersion
                    ]
                )
            }
        }
    }

    /// Embed the query with whichever model version is actually usable
    /// for search and run the version-filtered scan. During a re-embed
    /// transition both spaces exist side by side — search the one with
    /// the LARGER coverage (ties favor the active model) so quality
    /// never dips mid-backfill: legacy keeps serving until the new
    /// model has embedded at least as much of the corpus.
    func searchText(_ query: String, topK: Int, chatIds: [Int64]? = nil) async -> [SearchResult] {
        let activeVersion = await EmbeddingService.shared.activeModelVersion
        var version = activeVersion
        if activeVersion != EmbeddingService.legacyModelVersion {
            let activeCount = await vectorCount(modelVersion: activeVersion)
            let legacyCount = await vectorCount(modelVersion: EmbeddingService.legacyModelVersion)
            if activeCount < legacyCount {
                version = EmbeddingService.legacyModelVersion
            }
        }
        guard let queryVector = await EmbeddingService.shared.embed(text: query, modelVersion: version) else {
            return []
        }
        return await search(query: queryVector, topK: topK, chatIds: chatIds, modelVersion: version)
    }

    // MARK: - Conversation chunks

    struct ChunkRecord: Sendable {
        let chatId: Int64
        let fromMessageId: Int64
        let toMessageId: Int64
        let anchorMessageId: Int64
        let vector: [Double]
        let textPreview: String
        let modelVersion: String
    }

    /// Replace the chunk tail for a chat: stale partial-tail chunks
    /// (from `replacingFromMessageId` onward) are deleted before the
    /// rebuilt set is inserted, so growing conversations don't leave
    /// orphaned overlapping windows behind.
    func storeChunks(
        _ records: [ChunkRecord],
        chatId: Int64,
        modelVersion: String,
        replacingFromMessageId: Int64
    ) async {
        do {
            try await DatabaseManager.shared.write { db in
                try db.execute(
                    sql: """
                        DELETE FROM embedding_chunks
                        WHERE chat_id = ? AND model_version = ? AND from_message_id >= ?
                        """,
                    arguments: [chatId, modelVersion, replacingFromMessageId]
                )
                for record in records {
                    try db.execute(
                        sql: """
                            INSERT OR REPLACE INTO embedding_chunks
                                (chat_id, from_message_id, to_message_id, anchor_message_id,
                                 model_version, vector, text_preview, created_at)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            record.chatId,
                            record.fromMessageId,
                            record.toMessageId,
                            record.anchorMessageId,
                            record.modelVersion,
                            Self.encode(record.vector),
                            record.textPreview,
                            Date().timeIntervalSince1970
                        ]
                    )
                }
            }
        } catch {
            print("[VectorStore] Failed to store chunk batch: \(error)")
        }
    }

    func chunkCount(modelVersion: String) async -> Int {
        (try? await DatabaseManager.shared.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM embedding_chunks WHERE model_version = ?",
                arguments: [modelVersion]
            ) ?? 0
        }) ?? 0
    }

    func vectorCount(modelVersion: String) async -> Int {
        (try? await DatabaseManager.shared.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM embeddings WHERE model_version = ?",
                arguments: [modelVersion]
            ) ?? 0
        }) ?? 0
    }

    func search(
        query: [Double],
        topK: Int,
        chatIds: [Int64]? = nil,
        modelVersion: String
    ) async -> [SearchResult] {
        guard !query.isEmpty, topK > 0 else { return [] }
        if let chatIds, chatIds.isEmpty { return [] }

        do {
            // Message vectors and conversation-chunk vectors share the
            // model space for one version, so they're scored together:
            // chunks project their anchor message id, letting short
            // messages be found through their window while longer ones
            // still match directly. Dedup below keeps the best score
            // per (chat, message).
            let chatFilter = chatIds.map { ids in
                "AND chat_id IN (\(Array(repeating: "?", count: ids.count).joined(separator: ", ")))"
            } ?? ""
            var arguments = StatementArguments()
            arguments += [modelVersion]
            for chatId in chatIds ?? [] { arguments += [chatId] }
            arguments += [modelVersion]
            for chatId in chatIds ?? [] { arguments += [chatId] }

            let rows: [(messageId: Int64, chatId: Int64, vectorData: Data)] = try await DatabaseManager.shared.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT message_id, chat_id, vector
                        FROM embeddings
                        WHERE model_version = ? \(chatFilter)
                        UNION ALL
                        SELECT anchor_message_id AS message_id, chat_id, vector
                        FROM embedding_chunks
                        WHERE model_version = ? \(chatFilter)
                        """,
                    arguments: arguments
                ).compactMap { row in
                    guard let vectorData: Data = row["vector"] else { return nil }
                    return (
                        messageId: row["message_id"],
                        chatId: row["chat_id"],
                        vectorData: vectorData
                    )
                }
            }

            let scoredResults = rows.compactMap { row -> SearchResult? in
                guard let candidateVector = Self.decode(row.vectorData) else { return nil }
                let score = Self.cosineSimilarity(lhs: query, rhs: candidateVector)
                return SearchResult(
                    messageId: row.messageId,
                    chatId: row.chatId,
                    score: score
                )
            }

            // A message can surface twice — its own vector and as a
            // chunk anchor. Keep the best score per (chat, message).
            var bestByKey: [String: SearchResult] = [:]
            bestByKey.reserveCapacity(scoredResults.count)
            for result in scoredResults {
                let key = "\(result.chatId):\(result.messageId)"
                if let existing = bestByKey[key], existing.score >= result.score { continue }
                bestByKey[key] = result
            }

            return bestByKey.values
                .sorted { lhs, rhs in
                    if lhs.score != rhs.score {
                        return lhs.score > rhs.score
                    }
                    if lhs.chatId != rhs.chatId {
                        return lhs.chatId < rhs.chatId
                    }
                    return lhs.messageId > rhs.messageId
                }
                .prefix(topK)
                .map { $0 }
        } catch {
            print("[VectorStore] Failed to search embeddings: \(error)")
            return []
        }
    }

    private static func encode(_ vector: [Double]) -> Data {
        vector.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return Data() }
            return Data(bytes: baseAddress, count: pointer.count * MemoryLayout<Double>.stride)
        }
    }

    private static func decode(_ data: Data) -> [Double]? {
        guard data.count.isMultiple(of: MemoryLayout<Double>.stride) else { return nil }
        let count = data.count / MemoryLayout<Double>.stride
        return data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return [] }
            let typedPointer = baseAddress.assumingMemoryBound(to: Double.self)
            return Array(UnsafeBufferPointer(start: typedPointer, count: count))
        }
    }

    private static func cosineSimilarity(lhs: [Double], rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return -1 }

        var dot = 0.0
        var lhsNorm = 0.0
        var rhsNorm = 0.0

        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            lhsNorm += lhs[index] * lhs[index]
            rhsNorm += rhs[index] * rhs[index]
        }

        guard lhsNorm > 0, rhsNorm > 0 else { return -1 }
        return dot / (sqrt(lhsNorm) * sqrt(rhsNorm))
    }
}
