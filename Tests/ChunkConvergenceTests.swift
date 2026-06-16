import XCTest
@testable import Pidgy

/// Regression guard for the "indexer pegs the CPU at idle" bug (#42):
/// the conversation-chunk backfill re-selected an active chat on every
/// pass and re-ran the embedding model on the same windows forever,
/// because the re-selection watermark (`chunked_through_message_id`)
/// could never reach the chat's newest message when that newest message
/// was a sticker / media / sub-threshold fragment — which, in a chat
/// app, it almost always is.
///
/// The fix advances the watermark to the newest message EXAMINED, not
/// the last message that happened to form a chunk. These tests pin both
/// halves: the pure watermark decision, and the actual re-selection SQL.
final class ChunkConvergenceTests: XCTestCase {
    private let modelVersion = "e5-multilingual-small-v1"

    // MARK: - Pure: the scan watermark clears an unchunkable tail

    func testScannedThroughReachesNewestEvenWithUnchunkableTail() {
        let chatId: Int64 = -100
        // Ten messages with real text → they form chunks. Then a sticker
        // and a media message (no text) as the newest arrivals — exactly
        // the tail the chunker can't emit a window for.
        var messages: [ConversationChunker.Message] = (1...10).map {
            ConversationChunker.Message(
                id: Int64($0 * 10),
                senderName: "Ann",
                text: "This is a real message number \($0) with enough words to chunk."
            )
        }
        messages.append(ConversationChunker.Message(id: 110, senderName: "Bob", text: nil)) // sticker
        messages.append(ConversationChunker.Message(id: 120, senderName: "Bob", text: nil)) // media

        let chunks = ConversationChunker.chunks(chatId: chatId, messages: messages)
        let newestExamined: Int64 = 120

        // The last chunk can only reach a real-text message — it lags the
        // newest arrival. This lag is precisely what used to re-trigger.
        XCTAssertLessThan(
            chunks.last!.toMessageId, newestExamined,
            "Chunker should leave the sticker/media tail unchunked"
        )
        // The scan watermark must clear it anyway.
        XCTAssertEqual(
            ConversationChunker.scannedThrough(messages: messages, prior: 0),
            newestExamined,
            "Scan watermark must reach the newest examined message, not the last chunk"
        )
        // Monotonic: never regresses below a prior mark.
        XCTAssertEqual(ConversationChunker.scannedThrough(messages: messages, prior: 200), 200)
    }

    // MARK: - Integration: the real trigger query converges

    func testChunkTriggerStopsReselectingAfterScanWatermarkAdvances() async throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pidgy-chunk-convergence-\(UUID().uuidString).db")
        await DatabaseManager.shared.close()
        await DatabaseManager.shared.configureForTesting(databaseURLOverride: dbURL, appSupportDirectoryOverride: nil)
        defer {
            Task { await DatabaseManager.shared.close() }
            try? FileManager.default.removeItem(at: dbURL)
        }

        let chatId: Int64 = -555
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var records: [DatabaseManager.MessageRecord] = (1...10).map {
            DatabaseManager.MessageRecord(
                id: Int64($0 * 10),
                chatId: chatId,
                senderUserId: 1,
                senderName: "Ann",
                date: base.addingTimeInterval(Double($0)),
                textContent: "This is a real message number \($0) with enough words to chunk.",
                mediaTypeRaw: nil,
                isOutgoing: false
            )
        }
        // Newest two arrivals are a sticker and a photo (no text).
        records.append(.init(id: 110, chatId: chatId, senderUserId: 2, senderName: "Bob",
                             date: base.addingTimeInterval(11), textContent: nil,
                             mediaTypeRaw: "sticker", isOutgoing: false))
        records.append(.init(id: 120, chatId: chatId, senderUserId: 2, senderName: "Bob",
                             date: base.addingTimeInterval(12), textContent: nil,
                             mediaTypeRaw: "photo", isOutgoing: false))
        await DatabaseManager.shared.upsertIndexedMessages(
            chatId: chatId, messages: records, preferredOldestMessageId: nil, isSearchReady: true
        )

        let convMessages = records.map {
            ConversationChunker.Message(id: $0.id, senderName: $0.senderName, text: $0.textContent)
        }
        let chunks = ConversationChunker.chunks(chatId: chatId, messages: convMessages)
        let lastChunkId = chunks.last!.toMessageId
        XCTAssertLessThan(lastChunkId, 120, "Precondition: tail is unchunkable")

        // OLD (buggy) behavior: key the watermark off the last chunk id.
        // The chat stays perpetually selected — this is the hot loop.
        await DatabaseManager.shared.setChunkState(
            chatId: chatId, modelVersion: modelVersion,
            coveredThrough: 0, chunkedThrough: lastChunkId
        )
        var pending = await DatabaseManager.shared.chatsNeedingChunking(modelVersion: modelVersion, limit: 10)
        XCTAssertTrue(pending.contains(chatId), "Reproduces the bug: lagging watermark re-selects the chat")

        // FIXED behavior: advance to the newest examined id.
        let scanned = ConversationChunker.scannedThrough(messages: convMessages, prior: lastChunkId)
        await DatabaseManager.shared.setChunkState(
            chatId: chatId, modelVersion: modelVersion,
            coveredThrough: 0, chunkedThrough: scanned
        )
        pending = await DatabaseManager.shared.chatsNeedingChunking(modelVersion: modelVersion, limit: 10)
        XCTAssertFalse(pending.contains(chatId), "Fix: chat drops out of the work set — loop can idle")

        // Quality preserved: a genuinely newer message re-selects the chat.
        await DatabaseManager.shared.upsertIndexedMessages(
            chatId: chatId,
            messages: [.init(id: 130, chatId: chatId, senderUserId: 1, senderName: "Ann",
                             date: base.addingTimeInterval(13),
                             textContent: "A brand new real message that should be indexed.",
                             mediaTypeRaw: nil, isOutgoing: false)],
            preferredOldestMessageId: nil, isSearchReady: true
        )
        pending = await DatabaseManager.shared.chatsNeedingChunking(modelVersion: modelVersion, limit: 10)
        XCTAssertTrue(pending.contains(chatId), "New real activity must still re-index the chat")
    }
}
