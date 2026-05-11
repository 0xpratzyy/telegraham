import Foundation

/// Lazily extracts and caches the compiled-truth profile for a single
/// person. The dashboard's person detail view asks for a profile when
/// it appears; this service either returns a cached one or kicks off
/// an AI extraction in the background.
///
/// Caching rules:
///  - Cached profile is fresh if `last_extracted_at` is within
///    `cacheTTL` AND the per-sender message count hasn't grown by more
///    than `staleGrowthFraction` since the last extraction.
///  - Otherwise we re-extract. Concurrent requests for the same user
///    coalesce onto the same inflight Task.
@MainActor
final class PersonProfileService: ObservableObject {
    static let shared = PersonProfileService()

    /// Profile freshness window. After 24h we re-summarize even when
    /// no new messages arrived — captures any prompt improvements
    /// landing in the meantime.
    private let cacheTTL: TimeInterval = 24 * 3_600

    /// Re-extract when the per-sender message count has grown by ≥30%
    /// since the last extraction. Avoids hitting AI on every new ping
    /// while still keeping the profile honest in active conversations.
    private let staleGrowthFraction: Double = 0.30

    /// Minimum number of substantive sender messages needed before we
    /// bother running the prompt. The system prompt itself returns
    /// "Not enough conversation yet." below this floor.
    private let minimumSenderMessages = 5

    /// How many messages to send to the LLM per extraction. Newest first.
    private let messageSampleSize = 50

    @Published private(set) var profilesByUserId: [Int64: PersonProfileSnapshot] = [:]

    private var inflight: [Int64: Task<PersonProfileSnapshot?, Never>] = [:]

    private init() {}

    /// Public entry point. Returns the latest known profile snapshot or
    /// nil if extraction failed and there's no cache to fall back on.
    /// Safe to call repeatedly — duplicate calls coalesce.
    func loadProfile(
        userId: Int64,
        personName: String,
        aiService: AIService,
        myUserId: Int64,
        chatTitleResolver: @escaping (Int64) -> String
    ) async -> PersonProfileSnapshot? {
        if let existing = inflight[userId] {
            return await existing.value
        }

        let task = Task<PersonProfileSnapshot?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.refreshIfNeeded(
                userId: userId,
                personName: personName,
                aiService: aiService,
                myUserId: myUserId,
                chatTitleResolver: chatTitleResolver
            )
        }
        inflight[userId] = task
        let result = await task.value
        inflight[userId] = nil
        return result
    }

    private func refreshIfNeeded(
        userId: Int64,
        personName: String,
        aiService: AIService,
        myUserId: Int64,
        chatTitleResolver: @escaping (Int64) -> String
    ) async -> PersonProfileSnapshot? {
        let cached = await DatabaseManager.shared.loadPersonProfile(userId: userId)
        let liveCount = await DatabaseManager.shared.messageCountForSender(userId: userId)

        // Surface whatever's cached immediately so the UI has something
        // to show even while we're deciding whether to refresh.
        if let cached, !cached.summary.isEmpty {
            profilesByUserId[userId] = PersonProfileSnapshot(
                userId: userId,
                summary: cached.summary,
                isLoading: false,
                lastExtractedAt: cached.lastExtractedAt
            )
        }

        let shouldRefresh = needsRefresh(cached: cached, liveCount: liveCount)
        guard shouldRefresh else {
            return profilesByUserId[userId]
        }

        guard liveCount >= minimumSenderMessages else {
            let snapshot = PersonProfileSnapshot(
                userId: userId,
                summary: "Not enough conversation yet.",
                isLoading: false,
                lastExtractedAt: Date()
            )
            await DatabaseManager.shared.upsertPersonProfile(
                userId: userId,
                summary: snapshot.summary,
                messageCountAtExtraction: liveCount
            )
            profilesByUserId[userId] = snapshot
            return snapshot
        }

        // Mark in-progress so the UI can render a skeleton next to any
        // stale cached text. If the cache is empty, this is the first
        // visible state for the section.
        profilesByUserId[userId] = PersonProfileSnapshot(
            userId: userId,
            summary: profilesByUserId[userId]?.summary ?? "",
            isLoading: true,
            lastExtractedAt: profilesByUserId[userId]?.lastExtractedAt
        )

        let records = await DatabaseManager.shared.loadRecentMessages(
            fromSender: userId,
            limit: messageSampleSize
        )

        let tgMessages = records.map { record -> TGMessage in
            let senderId: TGMessage.MessageSenderId = record.senderUserId.map { .user($0) }
                ?? .chat(record.chatId)
            return TGMessage(
                id: record.id,
                chatId: record.chatId,
                senderId: senderId,
                date: record.date,
                textContent: record.textContent,
                mediaType: record.mediaTypeRaw.flatMap(TGMessage.MediaType.init(rawValue:)),
                isOutgoing: record.isOutgoing,
                chatTitle: chatTitleResolver(record.chatId),
                senderName: record.senderName
            )
        }

        do {
            let summary = try await aiService.extractPersonProfile(
                personName: personName,
                messages: tgMessages,
                myUserId: myUserId,
                chatTitleResolver: chatTitleResolver
            )
            let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                profilesByUserId[userId] = PersonProfileSnapshot(
                    userId: userId,
                    summary: profilesByUserId[userId]?.summary ?? "",
                    isLoading: false,
                    lastExtractedAt: profilesByUserId[userId]?.lastExtractedAt
                )
                return profilesByUserId[userId]
            }
            await DatabaseManager.shared.upsertPersonProfile(
                userId: userId,
                summary: trimmed,
                messageCountAtExtraction: liveCount
            )
            let snapshot = PersonProfileSnapshot(
                userId: userId,
                summary: trimmed,
                isLoading: false,
                lastExtractedAt: Date()
            )
            profilesByUserId[userId] = snapshot
            return snapshot
        } catch {
            print("[PersonProfileService] extract failed for \(userId): \(error)")
            // Clear loading state but keep any stale cached summary.
            profilesByUserId[userId] = PersonProfileSnapshot(
                userId: userId,
                summary: profilesByUserId[userId]?.summary ?? "",
                isLoading: false,
                lastExtractedAt: profilesByUserId[userId]?.lastExtractedAt
            )
            return profilesByUserId[userId]
        }
    }

    private func needsRefresh(
        cached: DatabaseManager.PersonProfileRecord?,
        liveCount: Int
    ) -> Bool {
        guard let cached, !cached.summary.isEmpty else { return true }
        if Date().timeIntervalSince(cached.lastExtractedAt) > cacheTTL { return true }
        guard cached.messageCountAtExtraction > 0 else { return true }
        let growth = Double(liveCount - cached.messageCountAtExtraction) / Double(cached.messageCountAtExtraction)
        return growth >= staleGrowthFraction
    }
}

struct PersonProfileSnapshot: Equatable, Sendable {
    let userId: Int64
    let summary: String
    let isLoading: Bool
    let lastExtractedAt: Date?
}
