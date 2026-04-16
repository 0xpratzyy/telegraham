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
    }

    func store(messageId: Int64, chatId: Int64, vector: [Double], textPreview: String) async {
        await storeBatch([
            EmbeddingRecord(
                messageId: messageId,
                chatId: chatId,
                vector: vector,
                textPreview: textPreview
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
                        INSERT INTO embeddings (message_id, chat_id, vector, text_preview)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(message_id, chat_id) DO UPDATE SET
                            vector = excluded.vector,
                            text_preview = excluded.text_preview
                        """,
                    arguments: [
                        record.messageId,
                        record.chatId,
                        Self.encode(record.vector),
                        record.textPreview
                    ]
                )
            }
        }
    }

    func search(query: [Double], topK: Int, chatIds: [Int64]? = nil) async -> [SearchResult] {
        guard !query.isEmpty, topK > 0 else { return [] }
        if let chatIds, chatIds.isEmpty { return [] }

        do {
            let rows: [(messageId: Int64, chatId: Int64, vectorData: Data)] = try await DatabaseManager.shared.read { db in
                if let chatIds {
                    let placeholders = Array(repeating: "?", count: chatIds.count).joined(separator: ", ")
                    var arguments = StatementArguments()
                    for chatId in chatIds {
                        arguments += [chatId]
                    }

                    return try Row.fetchAll(
                        db,
                        sql: """
                            SELECT message_id, chat_id, vector
                            FROM embeddings
                            WHERE chat_id IN (\(placeholders))
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

                return try Row.fetchAll(
                    db,
                    sql: """
                        SELECT message_id, chat_id, vector
                        FROM embeddings
                        """
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

            return scoredResults
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
