import Foundation

/// A sliding window of consecutive messages prepared for embedding.
struct ConversationChunk: Sendable, Equatable {
    let chatId: Int64
    let fromMessageId: Int64
    let toMessageId: Int64
    /// Newest message in the window — search results anchor here so
    /// snippets and deep links keep working unchanged downstream.
    let anchorMessageId: Int64
    /// "Sender: text" lines joined by newlines; what gets embedded.
    let text: String
}

/// Pure window builder. Chat messages are often too short to carry
/// meaning alone ("sure", "sending it tomorrow") — windows of
/// consecutive messages with sender names prefixed give the embedding
/// model real context, and short messages become findable through
/// their neighbors.
enum ConversationChunker {
    struct Message: Sendable {
        let id: Int64
        let senderName: String?
        let text: String?
    }

    /// Build windows over `messages` (must be ordered oldest → newest).
    /// Windows take up to `windowSize` messages, capped by `maxChars`
    /// of combined text, advancing by `windowSize - overlap` so
    /// adjacent windows share context. Messages without usable text
    /// are skipped entirely; windows whose combined text is under
    /// `minContentChars` are dropped as noise.
    static func chunks(
        chatId: Int64,
        messages: [Message],
        windowSize: Int = AppConstants.Indexing.chunkWindowMessageCount,
        overlap: Int = AppConstants.Indexing.chunkWindowOverlap,
        maxChars: Int = AppConstants.Indexing.chunkWindowMaxCharacters,
        minContentChars: Int = AppConstants.Indexing.chunkWindowMinContentCharacters
    ) -> [ConversationChunk] {
        guard windowSize > 0 else { return [] }
        let stride = max(windowSize - max(overlap, 0), 1)

        // Pre-render eligible lines once.
        let lines: [(id: Int64, line: String)] = messages.compactMap { message in
            guard let raw = message.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { return nil }
            let sender = message.senderName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (sender?.isEmpty == false) ? sender! : "Someone"
            return (message.id, "\(name): \(raw)")
        }
        guard !lines.isEmpty else { return [] }

        var chunks: [ConversationChunk] = []
        var start = 0
        while start < lines.count {
            var end = start
            var charCount = 0
            while end < lines.count,
                  end - start < windowSize,
                  charCount + lines[end].line.count <= maxChars || end == start {
                charCount += lines[end].line.count
                end += 1
            }

            let window = lines[start..<end]
            let text = window.map(\.line).joined(separator: "\n")
            if text.count >= minContentChars,
               let first = window.first, let last = window.last {
                chunks.append(ConversationChunk(
                    chatId: chatId,
                    fromMessageId: first.id,
                    toMessageId: last.id,
                    anchorMessageId: last.id,
                    text: text
                ))
            }

            if end >= lines.count { break }
            start += max(min(stride, end - start), 1)
        }
        return chunks
    }

    /// The covered-through high-water mark for a chunk run: the end of
    /// the last window that was FULL (hit windowSize messages). The
    /// partial tail past it gets re-chunked when new messages arrive.
    /// Returns nil when no window was full — coverage shouldn't advance.
    static func coveredThrough(
        chunks: [ConversationChunk],
        messages: [Message],
        windowSize: Int = AppConstants.Indexing.chunkWindowMessageCount,
        overlap: Int = AppConstants.Indexing.chunkWindowOverlap
    ) -> Int64? {
        // A window is "full" when stride could advance past it without
        // losing unseen messages — approximate by requiring at least
        // (windowSize - overlap) messages strictly after its end.
        guard let lastChunk = chunks.last else { return nil }
        let eligibleIds = messages.compactMap { message -> Int64? in
            guard let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return message.id
        }
        let tailCount = eligibleIds.filter { $0 > lastChunk.toMessageId }.count
        if tailCount > 0 { return lastChunk.toMessageId }

        // Last chunk reaches the end of available messages — advance
        // coverage only to the chunk BEFORE it, so the tail window is
        // rebuilt (and replaced) as the conversation grows.
        guard chunks.count >= 2 else { return nil }
        return chunks[chunks.count - 2].toMessageId
    }
}
