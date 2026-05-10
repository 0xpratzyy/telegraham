import Foundation
import OSLog

actor MajorChatCoverageCoordinator {
    static let shared = MajorChatCoverageCoordinator()

    struct PassSummary: Sendable, Equatable {
        let scannedChats: Int
        let backfilledChats: Int
        let fetchedMessages: Int
        let historyCooldownUntil: Date?
    }

    private struct CoverageOutcome: Sendable {
        let chatId: Int64
        let fetchedMessages: Int
        let reachedTarget: Bool
        let errorDescription: String?
        let shouldStopPass: Bool
        let historyCooldownSeconds: TimeInterval?

        init(
            chatId: Int64,
            fetchedMessages: Int,
            reachedTarget: Bool,
            errorDescription: String?,
            shouldStopPass: Bool = false,
            historyCooldownSeconds: TimeInterval? = nil
        ) {
            self.chatId = chatId
            self.fetchedMessages = fetchedMessages
            self.reachedTarget = reachedTarget
            self.errorDescription = errorDescription
            self.shouldStopPass = shouldStopPass
            self.historyCooldownSeconds = historyCooldownSeconds
        }
    }

    private struct CoverageProgress: Sendable {
        var cursor: Int64 = 0
        var seenMessageIds = Set<Int64>()
        var fetchedMessages = 0
        var reachedTarget = false
        var shouldRetryIncompleteLocalScan = false
        var didTimeout = false
        var didReachHistoryStart = false
        var oldestCoveredAt: Date?
        var oldestCoveredMessageId: Int64 = 0
        var transientErrorDescription: String?
    }

    private struct CoverageCandidate: Sendable {
        let chat: TGChat
        let needsCoverage: Bool
        let lastCheckedAt: Date?
        let hasCoverageState: Bool
        let isSparse: Bool
        let debtRank: Int?
        let hasError: Bool
    }

    private struct CoverageTimeoutError: LocalizedError {
        let seconds: TimeInterval

        var errorDescription: String? {
            "chat history fetch timed out after \(Int(seconds)) seconds"
        }
    }

    private final class TimeoutRace<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var didResume = false

        func resume(_ result: Result<T, Error>, continuation: CheckedContinuation<T, Error>) {
            lock.lock()
            guard !didResume else {
                lock.unlock()
                return
            }
            didResume = true
            lock.unlock()

            continuation.resume(with: result)
        }
    }

    private var telegramService: TelegramService?
    private var processingTask: Task<Void, Never>?
    private var pendingImmediateReconcile = true
    private var historyCooldownUntil: Date?
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.pidgy.app",
        category: "MajorChatCoverage"
    )

    func start(using telegramService: TelegramService) async {
        self.telegramService = telegramService
        pendingImmediateReconcile = true
        logger.info("Major coverage start requested")

        guard processingTask == nil else { return }

        processingTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() async {
        let task = processingTask
        task?.cancel()
        processingTask = nil
        telegramService = nil
        pendingImmediateReconcile = false
        await task?.value
    }

    func refreshNow() async {
        pendingImmediateReconcile = true
    }

    func recoverNow() async {
        pendingImmediateReconcile = true
    }

    private func runLoop() async {
        while !Task.isCancelled {
            guard let telegramService else {
                try? await Task.sleep(
                    for: .milliseconds(Int(AppConstants.MajorChatCoverage.idlePollIntervalMilliseconds))
                )
                continue
            }

            let shouldRunNow = pendingImmediateReconcile
            if shouldRunNow {
                pendingImmediateReconcile = false
            }

            let summary = await reconcileOnce(
                using: telegramService,
                now: Date(),
                limit: shouldRunNow
                    ? AppConstants.MajorChatCoverage.recoveryMaxChatsPerPass
                    : AppConstants.MajorChatCoverage.maxChatsPerPass,
                historyFetchTimeoutSeconds: AppConstants.MajorChatCoverage.historyFetchTimeoutSeconds
            )
            logger.info(
                "Major coverage pass scanned=\(summary.scannedChats) backfilled=\(summary.backfilledChats) fetched=\(summary.fetchedMessages) immediate=\(shouldRunNow)"
            )

            let fallbackSleepMs = shouldRunNow
                ? AppConstants.MajorChatCoverage.activePollIntervalMilliseconds
                : AppConstants.MajorChatCoverage.idlePollIntervalMilliseconds
            let sleepMs = Self.sleepMilliseconds(
                historyCooldownUntil: summary.historyCooldownUntil,
                fallbackMilliseconds: fallbackSleepMs
            )
            try? await Task.sleep(for: .milliseconds(Int(sleepMs)))
        }
    }

    private func reconcileOnce(
        using telegramService: TelegramService,
        now: Date,
        limit: Int?,
        historyFetchTimeoutSeconds: TimeInterval,
        maxNetworkBatchesPerChatOverride: Int? = nil
    ) async -> PassSummary {
        if let historyCooldownUntil, historyCooldownUntil > now {
            logger.info(
                "Major coverage pass deferred until \(historyCooldownUntil, privacy: .public)"
            )
            return PassSummary(
                scannedChats: 0,
                backfilledChats: 0,
                fetchedMessages: 0,
                historyCooldownUntil: historyCooldownUntil
            )
        }
        historyCooldownUntil = nil

        let cutoff = Self.coverageCutoff(now: now)
        let debtChatIds = await DatabaseManager.shared.loadMajorCoverageDebtChatIds(
            limit: AppConstants.MajorChatCoverage.debtCandidateLimit,
            now: now,
            cutoff: cutoff,
            coverageVersion: AppConstants.MajorChatCoverage.coverageStateVersion,
            minMessageCount: AppConstants.MajorChatCoverage.minTrustedLocalCoverageMessages
        )
        let majorChats = await majorChats(using: telegramService, now: now, debtChatIds: debtChatIds)
        let prioritizedChats = await prioritizeCoverageCandidates(
            majorChats,
            now: now,
            debtChatIds: debtChatIds
        )
        let scanChats = Array(prioritizedChats.prefix(limit ?? prioritizedChats.count))
        var scannedChats = 0
        var backfilledChats = 0
        var fetchedMessages = 0

        logger.info(
            "Major coverage reconcile candidates=\(majorChats.count) debt=\(debtChatIds.count) scanning=\(scanChats.count)"
        )

        for chat in scanChats {
            guard !Task.isCancelled else { break }
            scannedChats += 1
            logger.info(
                "Major coverage chat \(chat.id, privacy: .public) starting coverage"
            )
            let outcome = await Self.ensureCoverage(
                for: chat,
                using: telegramService,
                now: now,
                historyFetchTimeoutSeconds: historyFetchTimeoutSeconds,
                maxNetworkBatchesPerChatOverride: maxNetworkBatchesPerChatOverride
            )
            if let errorDescription = outcome.errorDescription {
                logger.error(
                    "Major coverage chat \(outcome.chatId, privacy: .public) failed error=\(errorDescription, privacy: .public)"
                )
            } else if outcome.fetchedMessages > 0 || outcome.reachedTarget {
                logger.info(
                    "Major coverage chat \(outcome.chatId, privacy: .public) fetched=\(outcome.fetchedMessages) reachedTarget=\(outcome.reachedTarget)"
                )
            }
            if outcome.fetchedMessages > 0 {
                backfilledChats += 1
                fetchedMessages += outcome.fetchedMessages

                // Same hook as RecentSyncCoordinator: tell downstream
                // consumers (TaskIndex etc.) that fresh messages just hit
                // the local store. Coverage typically writes 30+ messages
                // per chat, which is exactly the kind of arrival that
                // should drive a Tasks refresh without waiting 8 min.
                NotificationCenter.default.post(
                    name: .pidgyMessagesUpdatedLocally,
                    object: nil,
                    userInfo: [
                        "chatIds": [outcome.chatId],
                        "messageCount": outcome.fetchedMessages,
                        "source": "majorChatCoverage"
                    ]
                )
            }
            if let historyCooldownSeconds = outcome.historyCooldownSeconds {
                let cooldownUntil = now.addingTimeInterval(historyCooldownSeconds)
                if historyCooldownUntil == nil || cooldownUntil > (historyCooldownUntil ?? .distantPast) {
                    historyCooldownUntil = cooldownUntil
                }
            }
            if outcome.shouldStopPass {
                logger.info(
                    "Major coverage pass stopping early after chat \(outcome.chatId, privacy: .public)"
                )
                break
            }
        }

        return PassSummary(
            scannedChats: scannedChats,
            backfilledChats: backfilledChats,
            fetchedMessages: fetchedMessages,
            historyCooldownUntil: historyCooldownUntil
        )
    }

    private func prioritizeCoverageCandidates(
        _ chats: [TGChat],
        now: Date,
        debtChatIds: [Int64]
    ) async -> [TGChat] {
        let cutoff = Self.coverageCutoff(now: now)
        let debtRankByChatId = Dictionary(uniqueKeysWithValues: debtChatIds.enumerated().map { index, chatId in
            (chatId, index)
        })
        var candidates: [CoverageCandidate] = []
        candidates.reserveCapacity(chats.count)

        for chat in chats {
            let state = await DatabaseManager.shared.loadChatCoverageState(chatId: chat.id)
            if state?.coverageVersion == AppConstants.MajorChatCoverage.coverageStateVersion,
               let nextRetryAt = state?.nextRetryAt,
               nextRetryAt > now {
                continue
            }

            let latestSeenMessageId = chat.lastMessage?.id ?? 0
            let messageCoverage = await DatabaseManager.shared.loadMessageCoverage(chatId: chat.id, since: cutoff)
            let needsCoverage = !Self.hasFreshTargetCoverage(
                state,
                latestSeenMessageId: latestSeenMessageId,
                cutoff: cutoff
            )
            candidates.append(CoverageCandidate(
                chat: chat,
                needsCoverage: needsCoverage,
                lastCheckedAt: state?.lastCheckedAt,
                hasCoverageState: state != nil,
                isSparse: (messageCoverage?.messageCount ?? 0) < AppConstants.MajorChatCoverage.minTrustedLocalCoverageMessages,
                debtRank: debtRankByChatId[chat.id],
                hasError: state?.lastError != nil
            ))
        }

        return candidates.sorted { lhs, rhs in
            if lhs.needsCoverage != rhs.needsCoverage {
                return lhs.needsCoverage
            }

            if lhs.needsCoverage {
                // Always prefer chats that don't currently have an error.
                // These tend to succeed in 1-2s via the local pass against
                // TDLib's cache. Putting them first means the user sees
                // steady progress instead of waiting through 25+ slow
                // network-timeout retries before any quick win lands.
                if lhs.hasError != rhs.hasError {
                    return !lhs.hasError
                }

                let lhsDebtRank = lhs.debtRank ?? Int.max
                let rhsDebtRank = rhs.debtRank ?? Int.max
                let lhsHasDebt = lhs.debtRank != nil
                let rhsHasDebt = rhs.debtRank != nil
                if lhsHasDebt != rhsHasDebt {
                    return lhsHasDebt
                }

                if lhsHasDebt && rhsHasDebt {
                    if lhsDebtRank != rhsDebtRank {
                        return lhsDebtRank < rhsDebtRank
                    }

                    let lhsDate = lhs.chat.lastActivityDate ?? .distantPast
                    let rhsDate = rhs.chat.lastActivityDate ?? .distantPast
                    if lhsDate != rhsDate {
                        return lhsDate > rhsDate
                    }
                }

                if lhs.hasCoverageState != rhs.hasCoverageState {
                    return lhs.hasCoverageState
                }

                if lhs.isSparse != rhs.isSparse {
                    return lhs.isSparse
                }

                let lhsDate = lhs.chat.lastActivityDate ?? .distantPast
                let rhsDate = rhs.chat.lastActivityDate ?? .distantPast
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }

                let lhsChecked = lhs.lastCheckedAt ?? .distantPast
                let rhsChecked = rhs.lastCheckedAt ?? .distantPast
                if lhsChecked != rhsChecked {
                    return lhsChecked < rhsChecked
                }
            }

            let lhsChecked = lhs.lastCheckedAt ?? .distantPast
            let rhsChecked = rhs.lastCheckedAt ?? .distantPast
            if lhsChecked != rhsChecked {
                return lhsChecked < rhsChecked
            }

            let lhsDate = lhs.chat.lastActivityDate ?? .distantPast
            let rhsDate = rhs.chat.lastActivityDate ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }

            return lhs.chat.id < rhs.chat.id
        }.map(\.chat)
    }

    private func majorChats(
        using telegramService: TelegramService,
        now: Date,
        debtChatIds: [Int64]
    ) async -> [TGChat] {
        let loadedChats = await MainActor.run {
            telegramService.chats
        }
        var chatsById: [Int64: TGChat] = [:]
        for chat in loadedChats {
            chatsById[chat.id] = chat
        }

        let missingDebtChatIds = debtChatIds
            .prefix(AppConstants.MajorChatCoverage.debtHydrationLimit)
            .filter { chatsById[$0] == nil }
        for chatId in missingDebtChatIds {
            guard !Task.isCancelled else { break }
            do {
                if let chat = try await telegramService.getChat(id: chatId) {
                    chatsById[chat.id] = chat
                    continue
                }
            } catch {
                logger.error(
                    "Major coverage debt hydrate chat \(chatId, privacy: .public) failed error=\(error.localizedDescription, privacy: .public)"
                )
            }
            chatsById[chatId] = await syntheticDebtChat(chatId: chatId)
        }

        let debtChatIdSet = Set(debtChatIds)
        return Array(chatsById.values)
            .filter { debtChatIdSet.contains($0.id) || Self.isPotentialMajorCoverageChat($0, now: now) }
            .sorted { lhs, rhs in
                let lhsDebtRank = debtChatIds.firstIndex(of: lhs.id)
                let rhsDebtRank = debtChatIds.firstIndex(of: rhs.id)
                if (lhsDebtRank != nil) != (rhsDebtRank != nil) {
                    return lhsDebtRank != nil
                }
                if let lhsDebtRank, let rhsDebtRank, lhsDebtRank != rhsDebtRank {
                    return lhsDebtRank < rhsDebtRank
                }
                let lhsDate = lhs.lastActivityDate ?? .distantPast
                let rhsDate = rhs.lastActivityDate ?? .distantPast
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
                if lhs.unreadCount != rhs.unreadCount {
                    return lhs.unreadCount > rhs.unreadCount
                }
                if lhs.order != rhs.order {
                    return lhs.order > rhs.order
                }
                return lhs.id < rhs.id
            }
    }

    private func syntheticDebtChat(chatId: Int64) async -> TGChat {
        let state = await DatabaseManager.shared.loadChatCoverageState(chatId: chatId)
        let messageCoverage = await DatabaseManager.shared.loadMessageCoverage(chatId: chatId)
        let latestMessageId = max(
            state?.latestSeenMessageId ?? 0,
            messageCoverage?.latestMessageId ?? 0
        )
        let latestDate = messageCoverage?.latestMessageDate ?? state?.lastCheckedAt
        let lastMessage: TGMessage?
        if latestMessageId > 0, let latestDate {
            lastMessage = TGMessage(
                id: latestMessageId,
                chatId: chatId,
                senderId: chatId < 0 ? .chat(chatId) : .user(chatId),
                date: latestDate,
                textContent: nil,
                mediaType: nil,
                isOutgoing: false,
                chatTitle: nil,
                senderName: nil
            )
        } else {
            lastMessage = nil
        }

        let chatType: TGChat.ChatType = chatId < 0
            ? .basicGroup(groupId: -chatId)
            : .privateChat(userId: chatId)
        return TGChat(
            id: chatId,
            title: "Debt chat \(chatId)",
            chatType: chatType,
            unreadCount: 0,
            lastMessage: lastMessage,
            memberCount: nil,
            order: 0,
            isInMainList: false,
            smallPhotoFileId: nil
        )
    }

    private static func resolvedMemberCount(
        for chat: TGChat,
        using telegramService: TelegramService
    ) async -> Int? {
        try? await withTimeout(
            seconds: AppConstants.MajorChatCoverage.memberCountResolutionTimeoutSeconds
        ) {
            await telegramService.resolvedMemberCount(for: chat)
        }
    }

    private nonisolated static func isPotentialMajorCoverageChat(_ chat: TGChat, now: Date) -> Bool {
        guard isPotentialCoverageEligible(chat) else { return false }
        guard chat.unreadCount == 0 else { return true }
        guard let lastActivityDate = chat.lastActivityDate else { return false }
        return lastActivityDate >= coverageCutoff(now: now)
    }

    private nonisolated static func isPotentialCoverageEligible(_ chat: TGChat) -> Bool {
        switch chat.chatType {
        case .privateChat:
            return true
        case .basicGroup:
            return true
        case .supergroup(_, let isChannel):
            guard !isChannel else { return false }
            guard let memberCount = chat.memberCount else { return true }
            return memberCount <= AppConstants.Indexing.maxIndexedGroupMembers
        case .secretChat:
            return false
        }
    }

    private static func resolvedCoverageChat(
        _ chat: TGChat,
        using telegramService: TelegramService
    ) async -> TGChat? {
        switch chat.chatType {
        case .privateChat, .basicGroup:
            return chat
        case .supergroup(_, let isChannel):
            guard !isChannel else { return nil }
            if let memberCount = chat.memberCount {
                return memberCount <= AppConstants.Indexing.maxIndexedGroupMembers ? chat : nil
            }
            guard let memberCount = await resolvedMemberCount(for: chat, using: telegramService),
                  memberCount <= AppConstants.Indexing.maxIndexedGroupMembers else {
                return nil
            }
            return chat.updating(memberCount: memberCount)
        case .secretChat:
            return nil
        }
    }

    private nonisolated static func coverageCutoff(now: Date) -> Date {
        now.addingTimeInterval(-(AppConstants.MajorChatCoverage.coverageWindowDays * 86_400))
    }

    private static func ensureCoverage(
        for chat: TGChat,
        using telegramService: TelegramService,
        now: Date,
        historyFetchTimeoutSeconds: TimeInterval,
        maxNetworkBatchesPerChatOverride: Int? = nil
    ) async -> CoverageOutcome {
        let cutoff = coverageCutoff(now: now)
        let latestSeenMessageId = chat.lastMessage?.id ?? 0
        guard let coverageChat = await resolvedCoverageChat(chat, using: telegramService) else {
            await saveCoverageState(
                chatId: chat.id,
                oldestCoveredAt: nil,
                latestSeenMessageId: latestSeenMessageId,
                checkedAt: now,
                isMajor: false,
                lastError: nil,
                failureCount: 0,
                nextRetryAt: now.addingTimeInterval(AppConstants.MajorChatCoverage.incompleteLocalRetryDelaySeconds)
            )
            return CoverageOutcome(
                chatId: chat.id,
                fetchedMessages: 0,
                reachedTarget: false,
                errorDescription: nil
            )
        }

        let state = await DatabaseManager.shared.loadChatCoverageState(chatId: coverageChat.id)
        var progress = CoverageProgress()

        do {
            let recentMessageCoverage = await DatabaseManager.shared.loadMessageCoverage(
                chatId: coverageChat.id,
                since: cutoff
            )
            let recentSyncState = await DatabaseManager.shared.loadRecentSyncState(chatId: coverageChat.id)

            if Self.hasFreshTargetCoverage(state, latestSeenMessageId: latestSeenMessageId, cutoff: cutoff),
               let oldestDate = state?.oldestCoveredAt {
                await saveCoverageState(
                    chatId: coverageChat.id,
                    oldestCoveredAt: oldestDate,
                    oldestCoveredMessageId: state?.oldestCoveredMessageId ?? 0,
                    latestSeenMessageId: latestSeenMessageId,
                    checkedAt: now,
                    isMajor: true,
                    lastError: nil,
                    failureCount: 0,
                    nextRetryAt: nil
                )
                return CoverageOutcome(
                    chatId: coverageChat.id,
                    fetchedMessages: 0,
                    reachedTarget: true,
                    errorDescription: nil
                )
            }

            let bridgeState = Self.trustedCoveredStateForBridge(
                state,
                currentLatestSeenMessageId: latestSeenMessageId,
                cutoff: cutoff
            )
            let shouldPreferNetwork = Self.shouldPreferNetworkBackfill(
                state,
                recentMessageCoverage: recentMessageCoverage,
                cutoff: cutoff
            )
            if let durableCursor = Self.durableBackfillCursor(
                state,
                latestSeenMessageId: latestSeenMessageId,
                cutoff: cutoff
            ) {
                progress.cursor = durableCursor.messageId
                progress.oldestCoveredAt = durableCursor.messageDate
                progress.oldestCoveredMessageId = durableCursor.messageId
            }

            if progress.cursor == 0, let cachedCursor = Self.sparseBackfillCursor(
                recentMessageCoverage,
                recentSyncState: recentSyncState,
                latestSeenMessageId: latestSeenMessageId
            ) {
                progress.cursor = cachedCursor.messageId
                progress.oldestCoveredAt = cachedCursor.messageDate
                progress.oldestCoveredMessageId = cachedCursor.messageId
            }

            if !shouldPreferNetwork {
                progress = try await fetchCoverageBatches(
                    for: coverageChat,
                    using: telegramService,
                    cutoff: cutoff,
                    bridgeState: bridgeState,
                    onlyLocal: true,
                    historyFetchTimeoutSeconds: historyFetchTimeoutSeconds,
                    maxBatches: AppConstants.MajorChatCoverage.maxBatchesPerChat,
                    emptyPageRetryCount: AppConstants.MajorChatCoverage.localEmptyPageRetryCount,
                    interBatchDelayMilliseconds: 0,
                    startingProgress: progress
                )
            }

            if !progress.reachedTarget, !progress.didTimeout {
                progress.shouldRetryIncompleteLocalScan = false
                progress = try await fetchCoverageBatches(
                    for: coverageChat,
                    using: telegramService,
                    cutoff: cutoff,
                    bridgeState: bridgeState,
                    onlyLocal: false,
                    historyFetchTimeoutSeconds: AppConstants.MajorChatCoverage.networkHistoryFetchTimeoutSeconds,
                    maxBatches: maxNetworkBatchesPerChatOverride
                        ?? AppConstants.MajorChatCoverage.maxNetworkBatchesPerChat,
                    emptyPageRetryCount: 0,
                    interBatchDelayMilliseconds: AppConstants.MajorChatCoverage.networkBatchSpacingMilliseconds,
                    startingProgress: progress
                )
            }

            if let oldestCoveredAt = progress.oldestCoveredAt, oldestCoveredAt <= cutoff {
                progress.reachedTarget = true
            }
            // If this pass produced nothing (timeout, empty network, etc.) but
            // the previous state already had a valid oldest_covered_at, keep
            // it. Re-validating a v5/v7/v8 row whose local cache is now slow
            // shouldn't *delete* the prior coverage — that's exactly what was
            // turning previously-complete chats into NULL-oldest rows.
            let coverageBoundary: Date?
            if progress.reachedTarget {
                coverageBoundary = Self.earliest(progress.oldestCoveredAt, cutoff)
            } else if let progressOldest = progress.oldestCoveredAt {
                coverageBoundary = progressOldest
            } else {
                coverageBoundary = state?.oldestCoveredAt
            }
            let transientError = progress.transientErrorDescription
            let savedFailureCount = transientError == nil
                ? 0
                : max(0, state?.failureCount ?? 0) + 1
            let retryAt: Date?
            if progress.reachedTarget {
                retryAt = nil
            } else if transientError != nil {
                retryAt = now.addingTimeInterval(Self.retryBackoffDelay(failureCount: savedFailureCount))
            } else if progress.shouldRetryIncompleteLocalScan {
                retryAt = now.addingTimeInterval(AppConstants.MajorChatCoverage.incompleteLocalRetryDelaySeconds)
            } else {
                retryAt = nil
            }
            await saveCoverageState(
                chatId: coverageChat.id,
                oldestCoveredAt: coverageBoundary,
                oldestCoveredMessageId: progress.oldestCoveredMessageId,
                latestSeenMessageId: latestSeenMessageId,
                checkedAt: now,
                isMajor: true,
                lastError: transientError,
                failureCount: savedFailureCount,
                nextRetryAt: retryAt
            )
            return CoverageOutcome(
                chatId: coverageChat.id,
                fetchedMessages: progress.fetchedMessages,
                reachedTarget: progress.reachedTarget,
                errorDescription: nil
            )
        } catch {
            let failureCount = max(0, state?.failureCount ?? 0) + 1
            let oldestCoveredAt: Date?
            let oldestCoveredMessageId: Int64
            if let progressOldest = progress.oldestCoveredAt {
                oldestCoveredAt = progressOldest
                oldestCoveredMessageId = progress.oldestCoveredMessageId
            } else {
                oldestCoveredAt = await coverageDateAfterFailure(chatId: coverageChat.id)
                oldestCoveredMessageId = Self.currentVersionCursor(from: state)
            }
            let errorDescription = error.localizedDescription
            await saveCoverageState(
                chatId: coverageChat.id,
                oldestCoveredAt: oldestCoveredAt,
                oldestCoveredMessageId: oldestCoveredMessageId,
                latestSeenMessageId: latestSeenMessageId,
                checkedAt: now,
                isMajor: true,
                lastError: errorDescription,
                failureCount: failureCount,
                nextRetryAt: now.addingTimeInterval(Self.retryBackoffDelay(failureCount: failureCount))
            )
            return CoverageOutcome(
                chatId: coverageChat.id,
                fetchedMessages: progress.fetchedMessages,
                reachedTarget: false,
                errorDescription: errorDescription,
                shouldStopPass: Self.isRateLimitErrorDescription(errorDescription),
                historyCooldownSeconds: Self.isRateLimitErrorDescription(errorDescription)
                    ? AppConstants.MajorChatCoverage.transientHistoryFailureCooldownSeconds
                    : nil
            )
        }
    }

    private static func fetchCoverageBatches(
        for chat: TGChat,
        using telegramService: TelegramService,
        cutoff: Date,
        bridgeState: DatabaseManager.ChatCoverageStateRecord?,
        onlyLocal: Bool,
        historyFetchTimeoutSeconds: TimeInterval,
        maxBatches: Int,
        emptyPageRetryCount: Int,
        interBatchDelayMilliseconds: UInt64,
        startingProgress: CoverageProgress
    ) async throws -> CoverageProgress {
        var progress = startingProgress
        var emptyRetriesRemaining = emptyPageRetryCount

        for _ in 0..<maxBatches {
            guard !Task.isCancelled, !progress.reachedTarget else { break }
            let previousCursor = progress.cursor
            let requestCursor = progress.cursor

            let messages: [TGMessage]
            do {
                messages = try await withHistoryFetchTimeout(seconds: historyFetchTimeoutSeconds) {
                    try await telegramService.getChatHistory(
                        chatId: chat.id,
                        fromMessageId: requestCursor,
                        limit: AppConstants.MajorChatCoverage.historyBatchSize,
                        onlyLocal: onlyLocal,
                        priority: .background
                    )
                }
            } catch let error as CoverageTimeoutError {
                progress.didTimeout = true
                progress.transientErrorDescription = error.localizedDescription
                progress.shouldRetryIncompleteLocalScan = !progress.reachedTarget
                break
            }

            guard !messages.isEmpty else {
                if emptyRetriesRemaining > 0 {
                    emptyRetriesRemaining -= 1
                    try await sleepAfterEmptyLocalPage()
                    continue
                }
                if onlyLocal {
                    progress.shouldRetryIncompleteLocalScan = !progress.reachedTarget
                } else {
                    progress.didReachHistoryStart = true
                    progress.reachedTarget = true
                    progress.shouldRetryIncompleteLocalScan = false
                }
                break
            }
            emptyRetriesRemaining = emptyPageRetryCount

            let uniqueMessages = messages.filter { progress.seenMessageIds.insert($0.id).inserted }
            guard !uniqueMessages.isEmpty else {
                progress.shouldRetryIncompleteLocalScan = !progress.reachedTarget
                break
            }

            await DatabaseManager.shared.upsertLiveMessages(
                chatId: chat.id,
                messages: uniqueMessages.map(Self.messageRecord(from:)),
                updateRecentSyncState: requestCursor == 0
            )
            progress.fetchedMessages += uniqueMessages.count

            if let batchOldest = Self.oldestMessage(in: uniqueMessages) {
                progress.oldestCoveredAt = Self.earliest(progress.oldestCoveredAt, batchOldest.date)
                progress.oldestCoveredMessageId = batchOldest.id
                if batchOldest.date <= cutoff {
                    progress.reachedTarget = true
                    break
                }
            }

            if let bridgeState,
               messages.contains(where: { $0.id == bridgeState.latestSeenMessageId }) {
                progress.oldestCoveredAt = Self.earliest(progress.oldestCoveredAt, bridgeState.oldestCoveredAt)
                if bridgeState.oldestCoveredMessageId > 0 {
                    progress.oldestCoveredMessageId = bridgeState.oldestCoveredMessageId
                }
                progress.reachedTarget = true
                break
            }

            progress.cursor = Self.oldestMessage(in: messages)?.id ?? previousCursor
            if progress.cursor == 0 || progress.cursor == previousCursor {
                break
            }

            if !onlyLocal, interBatchDelayMilliseconds > 0 {
                try await sleepBetweenNetworkBatches(milliseconds: interBatchDelayMilliseconds)
            }
        }

        if !progress.reachedTarget,
           !progress.didTimeout,
           !progress.didReachHistoryStart {
            progress.shouldRetryIncompleteLocalScan = true
        }

        return progress
    }

    private static func sleepAfterEmptyLocalPage() async throws {
        let milliseconds = AppConstants.MajorChatCoverage.localEmptyPageRetryDelayMilliseconds
        guard milliseconds > 0 else { return }
        try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }

    private static func sleepBetweenNetworkBatches(milliseconds: UInt64) async throws {
        guard milliseconds > 0 else { return }
        try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }

    private nonisolated static func retryBackoffDelay(failureCount: Int) -> TimeInterval {
        let backoffs = AppConstants.MajorChatCoverage.retryBackoffSeconds
        guard !backoffs.isEmpty else { return 0 }
        let index = min(max(1, failureCount) - 1, backoffs.count - 1)
        return backoffs[index]
    }

    private nonisolated static func isRateLimitErrorDescription(_ description: String) -> Bool {
        let normalized = description.uppercased()
        return normalized.contains("FLOOD_WAIT")
            || normalized.contains("RATE_LIMIT")
            || normalized.contains("TOO MANY REQUESTS")
    }

    private nonisolated static func sleepMilliseconds(
        historyCooldownUntil: Date?,
        fallbackMilliseconds: UInt64
    ) -> UInt64 {
        guard let historyCooldownUntil else { return fallbackMilliseconds }
        let remaining = historyCooldownUntil.timeIntervalSinceNow
        guard remaining > 0 else { return fallbackMilliseconds }
        return max(1_000, UInt64(remaining * 1_000))
    }

    private nonisolated static func hasFreshTargetCoverage(
        _ state: DatabaseManager.ChatCoverageStateRecord?,
        latestSeenMessageId: Int64,
        cutoff: Date
    ) -> Bool {
        guard latestSeenMessageId != 0,
              let state,
              state.coverageVersion == AppConstants.MajorChatCoverage.coverageStateVersion,
              state.lastError == nil,
              let oldestCoveredAt = state.oldestCoveredAt else {
            return false
        }
        // We deliberately do NOT require state.latestSeenMessageId == latestSeenMessageId.
        // New messages arriving via live updates change `latestSeenMessageId` and used
        // to force a full re-validation through TDLib, which sometimes timed out on
        // large chats and flipped them OK -> FAIL even when the durable cursor was
        // still well past the 30-day cutoff. The new live messages flow into pidgy.db
        // through the normal update pipeline, so coverage stays valid as long as the
        // saved oldest is past cutoff. The wrapping caller refreshes the saved
        // latestSeenMessageId every time we hit this path so the state stays in sync.
        return oldestCoveredAt <= cutoff
    }

    private nonisolated static func shouldPreferNetworkBackfill(
        _ state: DatabaseManager.ChatCoverageStateRecord?,
        recentMessageCoverage: DatabaseManager.MessageCoverageRecord?,
        cutoff: Date
    ) -> Bool {
        guard let state else { return false }
        let hasOldVersionDebt = state.coverageVersion < AppConstants.MajorChatCoverage.coverageStateVersion
        let hasIncompleteCoverage = state.oldestCoveredAt == nil || (state.oldestCoveredAt ?? .distantFuture) > cutoff
        let isRecentWindowSparse = (recentMessageCoverage?.messageCount ?? 0) < AppConstants.MajorChatCoverage.minTrustedLocalCoverageMessages
        let hasFetchDebt = state.lastError != nil || state.nextRetryAt != nil
        if state.coverageVersion == AppConstants.MajorChatCoverage.coverageStateVersion, hasIncompleteCoverage {
            return true
        }
        return isRecentWindowSparse && (hasOldVersionDebt || hasFetchDebt)
    }

    private nonisolated static func durableBackfillCursor(
        _ state: DatabaseManager.ChatCoverageStateRecord?,
        latestSeenMessageId: Int64,
        cutoff: Date
    ) -> (messageId: Int64, messageDate: Date?)? {
        guard let state,
              state.coverageVersion == AppConstants.MajorChatCoverage.coverageStateVersion,
              state.latestSeenMessageId == latestSeenMessageId,
              state.oldestCoveredMessageId > 0,
              state.oldestCoveredAt == nil || (state.oldestCoveredAt ?? .distantFuture) > cutoff else {
            return nil
        }
        return (state.oldestCoveredMessageId, state.oldestCoveredAt)
    }

    private nonisolated static func sparseBackfillCursor(
        _ messageCoverage: DatabaseManager.MessageCoverageRecord?,
        recentSyncState: DatabaseManager.RecentSyncStateRecord?,
        latestSeenMessageId: Int64
    ) -> (messageId: Int64, messageDate: Date?)? {
        guard latestSeenMessageId != 0,
              let messageCoverage,
              messageCoverage.messageCount < AppConstants.MajorChatCoverage.minTrustedLocalCoverageMessages else {
            return nil
        }

        if messageCoverage.latestMessageId == latestSeenMessageId {
            return (latestSeenMessageId, messageCoverage.latestMessageDate)
        }

        if recentSyncState?.latestSyncedMessageId == latestSeenMessageId {
            return (latestSeenMessageId, nil)
        }

        return nil
    }

    private nonisolated static func trustedCoveredStateForBridge(
        _ state: DatabaseManager.ChatCoverageStateRecord?,
        currentLatestSeenMessageId: Int64,
        cutoff: Date
    ) -> DatabaseManager.ChatCoverageStateRecord? {
        guard let state,
              state.coverageVersion == AppConstants.MajorChatCoverage.coverageStateVersion,
              state.latestSeenMessageId != 0,
              state.latestSeenMessageId != currentLatestSeenMessageId,
              state.lastError == nil,
              let oldestCoveredAt = state.oldestCoveredAt,
              oldestCoveredAt <= cutoff else {
            return nil
        }
        return state
    }

    private static func coverageDateAfterFailure(chatId: Int64) async -> Date? {
        // Return the previously-saved oldest_covered_at regardless of
        // coverage_version. The semantic of this field has been stable across
        // all versions (= oldest message we've confirmed coverage for) so a
        // transient failure during version migration shouldn't drop us back
        // to "no coverage" if we already had a valid value.
        let state = await DatabaseManager.shared.loadChatCoverageState(chatId: chatId)
        return state?.oldestCoveredAt
    }

    private nonisolated static func currentVersionCursor(
        from state: DatabaseManager.ChatCoverageStateRecord?
    ) -> Int64 {
        guard state?.coverageVersion == AppConstants.MajorChatCoverage.coverageStateVersion else {
            return 0
        }
        return state?.oldestCoveredMessageId ?? 0
    }

    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard seconds > 0 else {
            throw CoverageTimeoutError(seconds: seconds)
        }
        let nanoseconds = UInt64((seconds * 1_000_000_000).rounded(.up))

        let operationTask = Task {
            try await operation()
        }
        let timeoutTask = Task<T, Error> {
            try await Task.sleep(nanoseconds: nanoseconds)
            throw CoverageTimeoutError(seconds: seconds)
        }

        defer {
            operationTask.cancel()
            timeoutTask.cancel()
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let race = TimeoutRace<T>()
                Task {
                    do {
                        let value = try await operationTask.value
                        race.resume(.success(value), continuation: continuation)
                    } catch {
                        race.resume(.failure(error), continuation: continuation)
                    }
                }
                Task {
                    do {
                        let value = try await timeoutTask.value
                        race.resume(.success(value), continuation: continuation)
                    } catch {
                        race.resume(.failure(error), continuation: continuation)
                    }
                }
            }
        } onCancel: {
            operationTask.cancel()
            timeoutTask.cancel()
        }
    }

    private static func withHistoryFetchTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard seconds > 0 else {
            throw CoverageTimeoutError(seconds: seconds)
        }
        let nanoseconds = UInt64((seconds * 1_000_000_000).rounded(.up))

        // We rely on RateLimiter.isHistoryCallInFlight (held inside
        // TelegramService.withRateLimitedCall until TDLib actually responds)
        // for serialization between successive history fetches. After a
        // timeout the underlying TDLibKit call keeps running; the next
        // backfill request blocks at the rate-limiter until that call drains,
        // which prevents a pile-up of in-flight TDLib requests without us
        // having to hold any extra coordinator-level gate.
        let operationTask = Task<T, Error> {
            try await operation()
        }
        let timeoutTask = Task<T, Error> {
            try await Task.sleep(nanoseconds: nanoseconds)
            throw CoverageTimeoutError(seconds: seconds)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let race = TimeoutRace<T>()
                Task {
                    do {
                        let value = try await operationTask.value
                        timeoutTask.cancel()
                        race.resume(.success(value), continuation: continuation)
                    } catch {
                        timeoutTask.cancel()
                        race.resume(.failure(error), continuation: continuation)
                    }
                }
                Task {
                    do {
                        let value = try await timeoutTask.value
                        race.resume(.success(value), continuation: continuation)
                    } catch is CancellationError {
                        // The operation completed first and cancelled the timer.
                    } catch {
                        // Timer fired before TDLib responded. Surface the
                        // timeout to the caller; operationTask keeps running
                        // until TDLib drains, holding the rate-limiter slot
                        // so the next caller blocks naturally.
                        race.resume(.failure(error), continuation: continuation)
                    }
                }
            }
        } onCancel: {
            operationTask.cancel()
            timeoutTask.cancel()
        }
    }

    private nonisolated static func oldestMessage(in messages: [TGMessage]) -> TGMessage? {
        messages.min { lhs, rhs in
            if lhs.date != rhs.date {
                return lhs.date < rhs.date
            }
            return lhs.id < rhs.id
        }
    }

    private nonisolated static func earliest(_ lhs: Date?, _ rhs: Date?) -> Date? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return min(lhs, rhs)
    }

    private static func saveCoverageState(
        chatId: Int64,
        oldestCoveredAt: Date?,
        oldestCoveredMessageId: Int64 = 0,
        latestSeenMessageId: Int64,
        checkedAt: Date,
        isMajor: Bool,
        lastError: String?,
        failureCount: Int,
        nextRetryAt: Date?
    ) async {
        await DatabaseManager.shared.saveChatCoverageState(
            DatabaseManager.ChatCoverageStateRecord(
                chatId: chatId,
                oldestCoveredAt: oldestCoveredAt,
                oldestCoveredMessageId: oldestCoveredMessageId,
                latestSeenMessageId: latestSeenMessageId,
                lastCheckedAt: checkedAt,
                isMajor: isMajor,
                lastError: lastError,
                failureCount: failureCount,
                nextRetryAt: nextRetryAt,
                coverageVersion: AppConstants.MajorChatCoverage.coverageStateVersion
            )
        )
    }

    private nonisolated static func messageRecord(from message: TGMessage) -> DatabaseManager.MessageRecord {
        DatabaseManager.MessageRecord(
            id: message.id,
            chatId: message.chatId,
            senderUserId: message.senderUserId,
            senderName: message.senderName,
            date: message.date,
            textContent: message.textContent,
            mediaTypeRaw: message.mediaType?.rawValue,
            isOutgoing: message.isOutgoing
        )
    }

#if DEBUG
    func reconcileOnceForTesting(
        using telegramService: TelegramService,
        now: Date,
        maxNetworkBatchesPerChatOverride: Int? = nil
    ) async -> PassSummary {
        await reconcileOnce(
            using: telegramService,
            now: now,
            limit: nil,
            historyFetchTimeoutSeconds: AppConstants.MajorChatCoverage.historyFetchTimeoutSeconds,
            maxNetworkBatchesPerChatOverride: maxNetworkBatchesPerChatOverride
        )
    }

    func reconcileOnceForTesting(
        using telegramService: TelegramService,
        now: Date,
        historyFetchTimeoutSeconds: TimeInterval
    ) async -> PassSummary {
        await reconcileOnce(
            using: telegramService,
            now: now,
            limit: nil,
            historyFetchTimeoutSeconds: historyFetchTimeoutSeconds
        )
    }

    func reconcileOnceForTesting(
        using telegramService: TelegramService,
        now: Date,
        limit: Int,
        historyFetchTimeoutSeconds: TimeInterval = AppConstants.MajorChatCoverage.historyFetchTimeoutSeconds
    ) async -> PassSummary {
        await reconcileOnce(
            using: telegramService,
            now: now,
            limit: limit,
            historyFetchTimeoutSeconds: historyFetchTimeoutSeconds
        )
    }

    func majorChatsForTesting(using telegramService: TelegramService, now: Date) async -> [TGChat] {
        let cutoff = Self.coverageCutoff(now: now)
        let debtChatIds = await DatabaseManager.shared.loadMajorCoverageDebtChatIds(
            limit: AppConstants.MajorChatCoverage.debtCandidateLimit,
            now: now,
            cutoff: cutoff,
            coverageVersion: AppConstants.MajorChatCoverage.coverageStateVersion,
            minMessageCount: AppConstants.MajorChatCoverage.minTrustedLocalCoverageMessages
        )
        return await majorChats(using: telegramService, now: now, debtChatIds: debtChatIds)
    }

    static func resetHistoryFetchGateForTesting() async {
        // No-op since the dedicated coordinator gate was removed in favour of
        // the rate-limiter's in-flight serialization. Kept for source compat
        // with existing test helpers.
    }
#endif
}
