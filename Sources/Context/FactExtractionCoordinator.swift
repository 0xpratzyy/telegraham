//
//  FactExtractionCoordinator.swift
//  Pidgy — #48 context layer
//
//  "Maintain, don't re-extract." Walks the active chats, and for each one feeds
//  only the messages NEW since its cursor (fact_extraction_state) into the fold,
//  folding in that chat's current open loops so the model can close the ones the
//  new messages answered. Incremental: every message is read exactly once.
//
//  Lives entirely behind ContextLayer.enabled — start() is a no-op when off, so
//  the whole feature is clean to keep or scrap.
//

import Combine
import Foundation
import OSLog

@MainActor
final class FactExtractionCoordinator: ObservableObject {
    static let shared = FactExtractionCoordinator()

    private weak var telegramService: TelegramService?
    private weak var aiService: AIService?
    private var passTask: Task<Void, Never>?
    private var timer: Timer?
    private var chatListCancellable: AnyCancellable?
    private var contactDirectory: FactContactDirectory?
    private var directoryBuiltAt: Date?
    private var isRunning = false

    @Published private(set) var lastPassAt: Date?
    @Published private(set) var lastPassNewFacts = 0

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.pidgy.app",
        category: "FactExtraction"
    )

    private init() {}

    /// Wire up the coordinator: an initial pass once Telegram is ready, then a
    /// periodic refresh. No-op unless the context layer is enabled.
    func start(telegramService: TelegramService, aiService: AIService) {
        guard ContextLayer.enabled else { return }
        self.telegramService = telegramService
        self.aiService = aiService

        // Re-run as TDLib streams the chat list in over time (debounced), so
        // coverage grows from the first few chats to the full active set.
        chatListCancellable = telegramService.$chats
            .debounce(for: .seconds(8), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.triggerPass() }
            }

        passTask?.cancel()
        passTask = Task { @MainActor [weak self] in
            // Wait for auth + a populated chat list (up to ~60s), then run.
            for _ in 0..<30 {
                if let ts = self?.telegramService, ts.authState == .ready, !ts.visibleChats.isEmpty { break }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            await self?.runPass()
        }

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 8 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.triggerPass() }
        }
    }

    /// Kick a pass if one isn't already running (used by the timer + any manual refresh).
    func triggerPass() {
        guard ContextLayer.enabled, !isRunning else { return }
        passTask?.cancel()
        passTask = Task { @MainActor [weak self] in await self?.runPass() }
    }

    /// Run a pass and return when it finishes — lets the inspector's "Run pass
    /// now" reload on real completion instead of guessing a delay. No-op if a
    /// pass is already in flight (runPass self-guards on isRunning).
    func runPassNow() async {
        guard ContextLayer.enabled else { return }
        await runPass()
    }

    private func runPass() async {
        guard ContextLayer.enabled, !isRunning,
              let telegramService, let aiService,
              telegramService.authState == .ready
        else { return }
        isRunning = true
        defer { isRunning = false }

        let myUserId = telegramService.currentUser?.id ?? 0
        let myUser = telegramService.currentUser
        let archived = ArchivedChatsStore.archivedIds()
        let cutoff = Date().addingTimeInterval(-ContextLayer.maxChatAgeSeconds)

        // Same eligibility as the task/reply surfaces: in the main list, not a
        // channel, not archived, small enough, and active within the window.
        let eligible = telegramService.visibleChats
            .filter { chat in
                guard chat.isInMainList, !chat.chatType.isChannel, !archived.contains(chat.id) else { return false }
                if let members = chat.memberCount, members > AppConstants.Indexing.maxIndexedGroupMembers { return false }
                return (chat.lastMessage?.date ?? .distantPast) >= cutoff
            }
            .sorted { ($0.lastMessage?.date ?? .distantPast) > ($1.lastMessage?.date ?? .distantPast) }
        // No prefix — iterate newest-active first and cap on chats actually
        // worked (those with fresh messages), so the backlog is covered across
        // passes instead of re-selecting the same newest 40 every time.

        // Global contact directory (cached ~5 min): lets the resolver reach
        // people only MENTIONED in a chat + unify the same person across chats.
        let directory: FactContactDirectory
        if let cached = contactDirectory, let at = directoryBuiltAt, Date().timeIntervalSince(at) < 300 {
            directory = cached
        } else {
            let rows = await DatabaseManager.shared.loadContactDirectory()
            let dmContacts: [(id: Int64, name: String)] = telegramService.visibleChats.compactMap { chat in
                if case .privateChat(let uid) = chat.chatType, uid != myUserId { return (uid, chat.title) }
                return nil
            }
            directory = FactContactDirectory.build(rows: rows, dmContacts: dmContacts)
            contactDirectory = directory
            directoryBuiltAt = Date()
        }

        var newFacts = 0
        var scannedWindows = 0
        var workedChats = 0
        for chat in eligible {
            guard !Task.isCancelled, workedChats < ContextLayer.maxChatsPerPass else { break }

            var cursor = await DatabaseManager.shared.factExtractionCursor(chatId: chat.id)
            var windows = 0
            var didWork = false
            // Forward crawl: walk this chat's 30-day window oldest-first in
            // chunks, a few per pass. The cursor persists, so a deep chat catches
            // up over subsequent passes rather than being read all at once.
            while windows < ContextLayer.maxWindowsPerChatPerPass {
                guard !Task.isCancelled else { break }
                let records = await DatabaseManager.shared.loadMessagesForward(
                    chatId: chat.id,
                    afterMessageId: cursor,
                    since: cutoff,
                    limit: ContextLayer.extractionWindow
                )
                guard !records.isEmpty else { break }
                didWork = true

                // Records are id ASC (chronological); extractFacts re-sorts by date too.
                let tgMessages = records.map { Self.tgMessage(from: $0, chatTitle: chat.title) }
                let openLoops = await DatabaseManager.shared
                    .loadOpenFacts(chatId: chat.id)
                    .filter { $0.predicate.isOpenLoop }

                do {
                    let result = try await aiService.extractFacts(
                        chat: chat,
                        newMessages: tgMessages,
                        openLoops: openLoops,
                        myUserId: myUserId,
                        myUser: myUser
                    )
                    // Resolve each subject to a canonical person id (DM
                    // counterparty / chat-sender match) so name variants collapse
                    // and facts join the People graph.
                    let resolved = result.drafts.map { draft -> FactDraft in
                        var d = draft
                        let (pid, name) = FactEntityResolver.resolve(
                            subject: draft.subjectEntity,
                            predicate: draft.predicate,
                            chat: chat,
                            myUserId: myUserId,
                            directory: directory
                        )
                        d.subjectPersonId = pid
                        d.subjectEntity = name
                        return d
                    }
                    if !resolved.isEmpty {
                        await DatabaseManager.shared.upsertFacts(resolved)
                        newFacts += resolved.count
                    }
                    // Anti-injection gate (mirrors the #30 task-completion defense):
                    // only HONOR a closure that a genuine outgoing/[ME] message in
                    // this window backs, and only for i_owe (something the USER
                    // delivers). "From me" is structural (isOutgoing / sender id),
                    // never message content, so a crafted inbound message can't
                    // forge a closure. owes_me is never closed from inbound text —
                    // that's left to the UI / recency expiry.
                    if !result.resolvedFingerprints.isEmpty {
                        let corroboratedByMe = records.contains {
                            $0.isOutgoing || (myUserId > 0 && $0.senderUserId == myUserId)
                        }
                        if corroboratedByMe {
                            let resolvedSet = Set(result.resolvedFingerprints)
                            let safe = openLoops
                                .filter { $0.predicate == .iOwe && resolvedSet.contains($0.fingerprint) }
                                .map(\.fingerprint)
                            if !safe.isEmpty {
                                await DatabaseManager.shared.invalidateFacts(fingerprints: safe)
                            }
                        }
                    }
                } catch {
                    logger.error("extractFacts failed for chat \(chat.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    break
                }

                cursor = records.map(\.id).max() ?? cursor
                await DatabaseManager.shared.updateFactExtractionCursor(chatId: chat.id, throughMessageId: cursor)
                windows += 1
                scannedWindows += 1
                if records.count < ContextLayer.extractionWindow { break } // caught up to now
                try? await Task.sleep(nanoseconds: 300_000_000) // gentle on the API
            }
            if didWork { workedChats += 1 }
        }

        lastPassAt = Date()
        lastPassNewFacts = newFacts
        logger.info("fact pass done: \(scannedWindows, privacy: .public) windows over \(workedChats, privacy: .public) chats, \(newFacts, privacy: .public) new facts")

        // If we filled the per-pass budget there's likely more backlog —
        // continue shortly (cursor-gated, so finished chats are skipped cheaply).
        // Only continue if this pass actually produced facts — if a full-budget
        // pass found nothing new, the backlog is content-empty and re-arming
        // would just churn. The 15s spacing keeps cold-start catch-up gentle.
        if workedChats >= ContextLayer.maxChatsPerPass, newFacts > 0 {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                self?.triggerPass()
            }
        }
    }

    private static func tgMessage(from record: DatabaseManager.MessageRecord, chatTitle: String?) -> TGMessage {
        let senderId: TGMessage.MessageSenderId = record.senderUserId.map { .user($0) } ?? .chat(record.chatId)
        return TGMessage(
            id: record.id,
            chatId: record.chatId,
            senderId: senderId,
            date: record.date,
            textContent: record.textContent,
            mediaType: record.mediaTypeRaw.flatMap(TGMessage.MediaType.init(rawValue:)),
            isOutgoing: record.isOutgoing,
            chatTitle: chatTitle,
            senderName: record.senderName
        )
    }
}
