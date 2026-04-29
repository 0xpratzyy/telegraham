import Foundation
import GRDB

actor GraphBuilder {
    static let shared = GraphBuilder()

    struct DebugCountRow: Sendable, Identifiable, Equatable {
        let id: String
        let label: String
        let count: Int
    }

    struct DebugTopContact: Sendable, Identifiable, Equatable {
        let id: Int64
        let displayName: String
        let category: String
        let interactionScore: Double
        let lastInteractionAt: Date?
    }

    struct DebugSummary: Sendable, Equatable {
        let processedChats: Int
        let totalChats: Int
        let lastUpdatedAt: Date?
        let nodeCounts: [DebugCountRow]
        let edgeCounts: [DebugCountRow]
        let topContacts: [DebugTopContact]

        static let empty = DebugSummary(
            processedChats: 0,
            totalChats: 0,
            lastUpdatedAt: nil,
            nodeCounts: [],
            edgeCounts: [],
            topContacts: []
        )

        var hasData: Bool {
            processedChats > 0 || totalChats > 0 || !nodeCounts.isEmpty || !edgeCounts.isEmpty || !topContacts.isEmpty
        }

        var isComplete: Bool {
            totalChats > 0 && processedChats >= totalChats
        }

        var completionFraction: Double {
            guard totalChats > 0 else { return 0 }
            return min(max(Double(processedChats) / Double(totalChats), 0), 1)
        }
    }

    private struct ProgressState: Sendable {
        let processedCount: Int
        let totalCount: Int
        let lastUpdatedAt: Date?
    }

    private struct GroupParticipant: Sendable, Hashable {
        let userId: Int64
        let messageCount: Int
        let lastActiveAt: Date?
    }

    private struct UserSnapshot: Sendable {
        let id: Int64
        let displayName: String
        let username: String?
        let isBot: Bool?
    }

    private struct ScoreMetric: Sendable {
        var messagesLast7Days = 0
        var messagesLast30Days = 0
        var lastInteractionAt: Date?
        var firstSeenAt: Date?
        var dmBonus = 0.0
        var unreadBonus = 0.0
    }

    private var buildTask: Task<Void, Never>?
    private var resolvedUsers: [Int64: UserSnapshot?] = [:]

    func buildIfNeeded(using telegramService: TelegramService) async {
        if let buildTask {
            await buildTask.value
            return
        }

        let task = Task {
            await self.performBuild(using: telegramService, forceFullScan: false)
        }
        buildTask = task
        await task.value
        buildTask = nil
    }

    func refresh(using telegramService: TelegramService) async {
        if let buildTask {
            await buildTask.value
        }

        let task = Task {
            await self.performBuild(using: telegramService, forceFullScan: true)
        }
        buildTask = task
        await task.value
        buildTask = nil
    }

    func debugSummary() async -> DebugSummary {
        do {
            return try await DatabaseManager.shared.read { db in
                let progressRow = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT last_indexed_message_id, total_messages_indexed, last_indexed_at
                        FROM sync_state
                        WHERE chat_id = ?
                        """,
                    arguments: [AppConstants.Graph.buildProgressChatId]
                )

                let processedChats = progressRow.map { max(Int(($0["last_indexed_message_id"] as Int64?) ?? 0), 0) } ?? 0
                let totalChats = progressRow.map { max(($0["total_messages_indexed"] as Int?) ?? 0, 0) } ?? 0
                let lastUpdatedAtSeconds: Double? = progressRow?["last_indexed_at"]

                let nodeRows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT entity_type, COUNT(*) AS row_count
                        FROM nodes
                        GROUP BY entity_type
                        ORDER BY entity_type COLLATE NOCASE ASC
                        """
                )

                let edgeRows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT edge_type, COUNT(*) AS row_count
                        FROM edges
                        GROUP BY edge_type
                        ORDER BY edge_type COLLATE NOCASE ASC
                        """
                )

                let topContactRows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT entity_id, display_name, username, category, interaction_score, last_interaction_at
                        FROM nodes
                        WHERE entity_type = ?
                        ORDER BY interaction_score DESC,
                                 last_interaction_at DESC,
                                 COALESCE(display_name, username, '') COLLATE NOCASE ASC
                        LIMIT 8
                        """,
                    arguments: [AppConstants.Graph.userEntityType]
                )

                return DebugSummary(
                    processedChats: processedChats,
                    totalChats: totalChats,
                    lastUpdatedAt: lastUpdatedAtSeconds.map(Date.init(timeIntervalSince1970:)),
                    nodeCounts: nodeRows.map { row in
                        let rawType: String = row["entity_type"]
                        return DebugCountRow(
                            id: rawType,
                            label: Self.prettyLabel(from: rawType),
                            count: row["row_count"]
                        )
                    },
                    edgeCounts: edgeRows.map { row in
                        let rawType: String = row["edge_type"]
                        return DebugCountRow(
                            id: rawType,
                            label: Self.prettyLabel(from: rawType),
                            count: row["row_count"]
                        )
                    },
                    topContacts: topContactRows.map { row in
                        let lastInteractionAtSeconds: Double? = row["last_interaction_at"]
                        let displayName: String = row["display_name"] ?? row["username"] ?? "Unknown"
                        return DebugTopContact(
                            id: row["entity_id"],
                            displayName: displayName,
                            category: row["category"],
                            interactionScore: row["interaction_score"],
                            lastInteractionAt: lastInteractionAtSeconds.map(Date.init(timeIntervalSince1970:))
                        )
                    }
                )
            }
        } catch {
            print("[GraphBuilder] Failed to load debug summary: \(error)")
            return .empty
        }
    }

    private func performBuild(using telegramService: TelegramService, forceFullScan: Bool) async {
        let currentUser = await MainActor.run { telegramService.currentUser }
        let visibleChats = await MainActor.run {
            telegramService.visibleChats
                .filter {
                    if case .secretChat = $0.chatType {
                        return false
                    }
                    return true
                }
                .sorted { $0.id < $1.id }
        }

        guard let currentUser else { return }

        await upsertSelfNode(currentUser)

        let progress = await loadProgressState()
        let chatsToProcess: [TGChat]
        let initialProcessed: Int
        let totalForProgress: Int

        if forceFullScan {
            chatsToProcess = visibleChats
            initialProcessed = 0
            totalForProgress = visibleChats.count
            print("[GraphBuilder] Refreshing graph across \(visibleChats.count) chats")
        } else if let progress, progress.processedCount < progress.totalCount, progress.totalCount > 0 {
            let safeProcessedCount = min(progress.processedCount, visibleChats.count)
            chatsToProcess = Array(visibleChats.dropFirst(safeProcessedCount))
            initialProcessed = safeProcessedCount
            totalForProgress = visibleChats.count
            print("[GraphBuilder] Resuming graph build at chat \(safeProcessedCount + 1) of \(visibleChats.count)")
        } else {
            let missingChats = await filterChatsMissingCoreNode(visibleChats)
            guard !missingChats.isEmpty else {
                print("[GraphBuilder] Graph build already complete")
                return
            }
            chatsToProcess = missingChats
            initialProcessed = 0
            totalForProgress = missingChats.count
            print("[GraphBuilder] Starting graph build for \(missingChats.count) chats")
        }

        await saveProgressState(processedCount: initialProcessed, totalCount: totalForProgress)

        for (offset, chat) in chatsToProcess.enumerated() {
            await process(chat: chat, currentUser: currentUser, telegramService: telegramService)
            await saveProgressState(
                processedCount: initialProcessed + offset + 1,
                totalCount: totalForProgress
            )
        }

        await applyInitialScores(currentUser: currentUser, chats: visibleChats)
        await saveProgressState(processedCount: totalForProgress, totalCount: totalForProgress)
        print("[GraphBuilder] Graph build finished")
    }

    private func process(chat: TGChat, currentUser: TGUser, telegramService: TelegramService) async {
        switch chat.chatType {
        case .privateChat(let userId):
            let resolvedUser = await resolveUser(
                userId: userId,
                fallbackName: chat.title,
                telegramService: telegramService
            )
            await upsertDirectMessageChat(
                chat: chat,
                currentUser: currentUser,
                otherUserId: userId,
                resolvedUser: resolvedUser
            )

        case .basicGroup, .supergroup(_, false):
            let participants = await loadTopParticipants(chatId: chat.id)
            let resolvedParticipants = await resolveParticipants(
                participants,
                currentUser: currentUser,
                telegramService: telegramService
            )
            await upsertGroupChat(
                chat: chat,
                currentUserId: currentUser.id,
                participants: resolvedParticipants
            )

        case .supergroup(_, true):
            await upsertChatNode(chat: chat, entityType: AppConstants.Graph.channelEntityType)

        case .secretChat:
            break
        }
    }

    private func resolveParticipants(
        _ participants: [GroupParticipant],
        currentUser: TGUser,
        telegramService: TelegramService
    ) async -> [GroupParticipant: UserSnapshot] {
        var resolved: [GroupParticipant: UserSnapshot] = [:]

        for participant in participants {
            if participant.userId == currentUser.id {
                resolved[participant] = UserSnapshot(
                    id: currentUser.id,
                    displayName: currentUser.displayName,
                    username: currentUser.username,
                    isBot: currentUser.isBot
                )
                continue
            }

            let resolvedUser = await resolveUser(
                userId: participant.userId,
                fallbackName: nil,
                telegramService: telegramService
            )
            if let resolvedUser {
                resolved[participant] = resolvedUser
            } else {
                resolved[participant] = UserSnapshot(
                    id: participant.userId,
                    displayName: "User \(participant.userId)",
                    username: nil,
                    isBot: nil
                )
            }
        }

        return resolved
    }

    private func resolveUser(
        userId: Int64,
        fallbackName: String?,
        telegramService: TelegramService
    ) async -> UserSnapshot? {
        if let cached = resolvedUsers[userId] {
            return cached
        }

        let snapshot: UserSnapshot?
        if let user = try? await telegramService.getUser(id: userId, priority: .background) {
            snapshot = UserSnapshot(
                id: user.id,
                displayName: user.displayName,
                username: user.username,
                isBot: user.isBot
            )
        } else if let fallbackName {
            snapshot = UserSnapshot(id: userId, displayName: fallbackName, username: nil, isBot: nil)
        } else {
            snapshot = nil
        }

        resolvedUsers[userId] = snapshot
        return snapshot
    }

    private func upsertSelfNode(_ currentUser: TGUser) async {
        do {
            try await DatabaseManager.shared.write { db in
                try Self.upsertNode(
                    in: db,
                    entityId: currentUser.id,
                    entityType: AppConstants.Graph.selfEntityType,
                    displayName: currentUser.displayName,
                    username: currentUser.username,
                    isBot: currentUser.isBot,
                    lastInteractionAt: nil,
                    firstSeenAt: Date()
                )
            }
        } catch {
            print("[GraphBuilder] Failed to upsert self node: \(error)")
        }
    }

    private func upsertDirectMessageChat(
        chat: TGChat,
        currentUser: TGUser,
        otherUserId: Int64,
        resolvedUser: UserSnapshot?
    ) async {
        do {
            try await DatabaseManager.shared.write { db in
                try Self.upsertNode(
                    in: db,
                    entityId: otherUserId,
                    entityType: AppConstants.Graph.userEntityType,
                    displayName: resolvedUser?.displayName ?? chat.title,
                    username: resolvedUser?.username,
                    isBot: resolvedUser?.isBot,
                    lastInteractionAt: chat.lastActivityDate,
                    firstSeenAt: chat.lastActivityDate
                )

                let messageCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM messages WHERE chat_id = ?",
                    arguments: [chat.id]
                ) ?? 0

                try Self.upsertEdge(
                    in: db,
                    source: currentUser.id,
                    target: otherUserId,
                    edgeType: AppConstants.Graph.dmEdgeType,
                    contextChatId: nil,
                    weight: AppConstants.Graph.directMessageBonus,
                    messageCount: messageCount,
                    lastActiveAt: chat.lastActivityDate
                )
            }
        } catch {
            print("[GraphBuilder] Failed to build DM graph for chat \(chat.id): \(error)")
        }
    }

    private func upsertGroupChat(
        chat: TGChat,
        currentUserId: Int64,
        participants: [GroupParticipant: UserSnapshot]
    ) async {
        do {
            try await DatabaseManager.shared.write { db in
                try Self.upsertNode(
                    in: db,
                    entityId: chat.id,
                    entityType: AppConstants.Graph.groupEntityType,
                    displayName: chat.title,
                    username: nil,
                    lastInteractionAt: chat.lastActivityDate,
                    firstSeenAt: chat.lastActivityDate
                )

                for resolvedUser in participants.values where resolvedUser.id != currentUserId {
                    try Self.upsertNode(
                        in: db,
                        entityId: resolvedUser.id,
                        entityType: AppConstants.Graph.userEntityType,
                        displayName: resolvedUser.displayName,
                        username: resolvedUser.username,
                        isBot: resolvedUser.isBot,
                        lastInteractionAt: nil,
                        firstSeenAt: nil
                    )
                }

                let orderedParticipants = participants.keys.sorted {
                    if $0.messageCount != $1.messageCount {
                        return $0.messageCount > $1.messageCount
                    }
                    return $0.userId < $1.userId
                }

                for lhsIndex in orderedParticipants.indices {
                    let lhs = orderedParticipants[lhsIndex]
                    for rhsIndex in orderedParticipants.indices where rhsIndex > lhsIndex {
                        let rhs = orderedParticipants[rhsIndex]
                        let source = min(lhs.userId, rhs.userId)
                        let target = max(lhs.userId, rhs.userId)
                        let pairMessageCount = min(lhs.messageCount, rhs.messageCount)
                        let lastActiveAt = [lhs.lastActiveAt, rhs.lastActiveAt, chat.lastActivityDate]
                            .compactMap { $0 }
                            .max()

                        try Self.upsertEdge(
                            in: db,
                            source: source,
                            target: target,
                            edgeType: AppConstants.Graph.sharedGroupEdgeType,
                            contextChatId: chat.id,
                            weight: 1,
                            messageCount: pairMessageCount,
                            lastActiveAt: lastActiveAt
                        )
                    }
                }
            }
        } catch {
            print("[GraphBuilder] Failed to build shared-group graph for chat \(chat.id): \(error)")
        }
    }

    private func upsertChatNode(chat: TGChat, entityType: String) async {
        do {
            try await DatabaseManager.shared.write { db in
                try Self.upsertNode(
                    in: db,
                    entityId: chat.id,
                    entityType: entityType,
                    displayName: chat.title,
                    username: nil,
                    lastInteractionAt: chat.lastActivityDate,
                    firstSeenAt: chat.lastActivityDate
                )
            }
        } catch {
            print("[GraphBuilder] Failed to upsert chat node \(chat.id): \(error)")
        }
    }

    private func loadTopParticipants(chatId: Int64) async -> [GroupParticipant] {
        do {
            return try await DatabaseManager.shared.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT sender_user_id,
                               COUNT(*) AS message_count,
                               MAX(date) AS last_active_at
                        FROM messages
                        WHERE chat_id = ?
                          AND sender_user_id IS NOT NULL
                        GROUP BY sender_user_id
                        ORDER BY message_count DESC, last_active_at DESC
                        LIMIT ?
                        """,
                    arguments: [chatId, AppConstants.Graph.groupParticipantLimit]
                )

                return rows.compactMap { row in
                    guard let userId: Int64 = row["sender_user_id"] else { return nil }
                    let lastActiveAtSeconds: Double? = row["last_active_at"]
                    return GroupParticipant(
                        userId: userId,
                        messageCount: row["message_count"],
                        lastActiveAt: lastActiveAtSeconds.map(Date.init(timeIntervalSince1970:))
                    )
                }
            }
        } catch {
            print("[GraphBuilder] Failed to load group participants for chat \(chatId): \(error)")
            return []
        }
    }

    private func filterChatsMissingCoreNode(_ chats: [TGChat]) async -> [TGChat] {
        do {
            return try await DatabaseManager.shared.read { db in
                let nodeIds = chats.compactMap(Self.coreEntityId(for:))
                guard !nodeIds.isEmpty else { return [] }

                let placeholders = Array(repeating: "?", count: nodeIds.count).joined(separator: ", ")
                var arguments = StatementArguments()
                for nodeId in nodeIds {
                    arguments += [nodeId]
                }

                let existingIds = Set(
                    try Int64.fetchAll(
                        db,
                        sql: "SELECT entity_id FROM nodes WHERE entity_id IN (\(placeholders))",
                        arguments: arguments
                    )
                )

                return chats.filter { chat in
                    guard let entityId = Self.coreEntityId(for: chat) else { return false }
                    return !existingIds.contains(entityId)
                }
            }
        } catch {
            print("[GraphBuilder] Failed to inspect graph nodes: \(error)")
            return chats
        }
    }

    private func loadProgressState() async -> ProgressState? {
        do {
            return try await DatabaseManager.shared.read { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT last_indexed_message_id, total_messages_indexed
                        FROM sync_state
                        WHERE chat_id = ?
                        """,
                    arguments: [AppConstants.Graph.buildProgressChatId]
                ) else {
                    return nil
                }

                let processed: Int64 = row["last_indexed_message_id"]
                let total: Int = row["total_messages_indexed"]
                let lastUpdatedAtSeconds: Double? = row["last_indexed_at"]
                return ProgressState(
                    processedCount: max(Int(processed), 0),
                    totalCount: max(total, 0),
                    lastUpdatedAt: lastUpdatedAtSeconds.map(Date.init(timeIntervalSince1970:))
                )
            }
        } catch {
            print("[GraphBuilder] Failed to load graph progress: \(error)")
            return nil
        }
    }

    private func saveProgressState(processedCount: Int, totalCount: Int) async {
        do {
            try await DatabaseManager.shared.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO sync_state (chat_id, last_indexed_message_id, last_indexed_at, total_messages_indexed, is_search_ready)
                        VALUES (?, ?, ?, ?, 0)
                        ON CONFLICT(chat_id) DO UPDATE SET
                            last_indexed_message_id = excluded.last_indexed_message_id,
                            last_indexed_at = excluded.last_indexed_at,
                            total_messages_indexed = excluded.total_messages_indexed
                        """,
                    arguments: [
                        AppConstants.Graph.buildProgressChatId,
                        processedCount,
                        Date().timeIntervalSince1970,
                        totalCount
                    ]
                )
            }
        } catch {
            print("[GraphBuilder] Failed to persist graph progress: \(error)")
        }
    }

    private func applyInitialScores(currentUser: TGUser, chats: [TGChat]) async {
        let recentCutoff = Date().addingTimeInterval(-AppConstants.Graph.scoreRecentWindowDays * 86400)
        let monthlyCutoff = Date().addingTimeInterval(-AppConstants.Graph.scoreMonthlyWindowDays * 86400)

        var metricsByUser: [Int64: ScoreMetric] = [:]

        for chat in chats {
            guard case .privateChat(let userId) = chat.chatType else { continue }
            if userId == currentUser.id { continue }

            var metric = metricsByUser[userId, default: ScoreMetric()]
            metric.dmBonus = AppConstants.Graph.directMessageBonus
            if chat.unreadCount > 0 {
                metric.unreadBonus = AppConstants.Graph.unreadBonus
            }
            if let lastActivityDate = chat.lastActivityDate {
                metric.lastInteractionAt = max(metric.lastInteractionAt ?? .distantPast, lastActivityDate)
                metric.firstSeenAt = min(metric.firstSeenAt ?? lastActivityDate, lastActivityDate)
            }
            metricsByUser[userId] = metric
        }

        do {
            let messageMetrics = try await DatabaseManager.shared.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT sender_user_id,
                               SUM(CASE WHEN date >= ? THEN 1 ELSE 0 END) AS messages_7d,
                               SUM(CASE WHEN date >= ? THEN 1 ELSE 0 END) AS messages_30d,
                               MAX(date) AS last_interaction_at,
                               MIN(date) AS first_seen_at
                        FROM messages
                        WHERE sender_user_id IS NOT NULL
                        GROUP BY sender_user_id
                        """,
                    arguments: [
                        recentCutoff.timeIntervalSince1970,
                        monthlyCutoff.timeIntervalSince1970
                    ]
                )

                return rows.compactMap { row -> (Int64, ScoreMetric)? in
                    guard let userId: Int64 = row["sender_user_id"] else { return nil }
                    let lastInteractionAtSeconds: Double? = row["last_interaction_at"]
                    let firstSeenAtSeconds: Double? = row["first_seen_at"]
                    var metric = ScoreMetric()
                    metric.messagesLast7Days = row["messages_7d"]
                    metric.messagesLast30Days = row["messages_30d"]
                    metric.lastInteractionAt = lastInteractionAtSeconds.map(Date.init(timeIntervalSince1970:))
                    metric.firstSeenAt = firstSeenAtSeconds.map(Date.init(timeIntervalSince1970:))
                    return (userId, metric)
                }
            }

            for (userId, metric) in messageMetrics {
                var merged = metricsByUser[userId, default: ScoreMetric()]
                merged.messagesLast7Days = max(merged.messagesLast7Days, metric.messagesLast7Days)
                merged.messagesLast30Days = max(merged.messagesLast30Days, metric.messagesLast30Days)
                if let lastInteractionAt = metric.lastInteractionAt {
                    merged.lastInteractionAt = max(merged.lastInteractionAt ?? .distantPast, lastInteractionAt)
                }
                if let firstSeenAt = metric.firstSeenAt {
                    merged.firstSeenAt = min(merged.firstSeenAt ?? firstSeenAt, firstSeenAt)
                }
                metricsByUser[userId] = merged
            }

            let finalMetricsByUser = metricsByUser
            try await DatabaseManager.shared.write { db in
                for (userId, metric) in finalMetricsByUser {
                    let score = (Double(metric.messagesLast7Days) * 3.0) +
                        Double(metric.messagesLast30Days) +
                        metric.dmBonus +
                        metric.unreadBonus

                    try db.execute(
                        sql: """
                            UPDATE nodes
                            SET interaction_score = ?,
                                last_interaction_at = MAX(COALESCE(last_interaction_at, 0), ?),
                                first_seen_at = CASE
                                    WHEN first_seen_at = 0 THEN ?
                                    WHEN ? = 0 THEN first_seen_at
                                    ELSE MIN(first_seen_at, ?)
                                END
                            WHERE entity_id = ?
                            """,
                        arguments: [
                            score,
                            metric.lastInteractionAt?.timeIntervalSince1970 ?? 0,
                            metric.firstSeenAt?.timeIntervalSince1970 ?? 0,
                            metric.firstSeenAt?.timeIntervalSince1970 ?? 0,
                            metric.firstSeenAt?.timeIntervalSince1970 ?? 0,
                            userId
                        ]
                    )
                }

                for chat in chats {
                    guard case .privateChat = chat.chatType else {
                        let entityId = chat.id
                        try db.execute(
                            sql: """
                                UPDATE nodes
                                SET last_interaction_at = MAX(COALESCE(last_interaction_at, 0), ?),
                                    first_seen_at = CASE
                                        WHEN first_seen_at = 0 THEN ?
                                        WHEN ? = 0 THEN first_seen_at
                                        ELSE MIN(first_seen_at, ?)
                                    END
                                WHERE entity_id = ?
                                """,
                            arguments: [
                                chat.lastActivityDate?.timeIntervalSince1970 ?? 0,
                                chat.lastActivityDate?.timeIntervalSince1970 ?? 0,
                                chat.lastActivityDate?.timeIntervalSince1970 ?? 0,
                                chat.lastActivityDate?.timeIntervalSince1970 ?? 0,
                                entityId
                            ]
                        )
                        continue
                    }
                }
            }
        } catch {
            print("[GraphBuilder] Failed to apply initial graph scores: \(error)")
        }
    }

    private static func coreEntityId(for chat: TGChat) -> Int64? {
        switch chat.chatType {
        case .privateChat(let userId):
            return userId
        case .basicGroup, .supergroup:
            return chat.id
        case .secretChat:
            return nil
        }
    }

    private static func prettyLabel(from rawValue: String) -> String {
        rawValue
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    private static func upsertNode(
        in db: Database,
        entityId: Int64,
        entityType: String,
        displayName: String?,
        username: String?,
        isBot: Bool? = nil,
        lastInteractionAt: Date?,
        firstSeenAt: Date?
    ) throws {
        let metadata = GraphNodeMetadata.encoded(isBot: isBot)

        try db.execute(
            sql: """
                INSERT INTO nodes (
                    entity_id,
                    entity_type,
                    display_name,
                    username,
                    category,
                    category_source,
                    interaction_score,
                    last_interaction_at,
                    first_seen_at,
                    metadata
                )
                VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?, ?)
                ON CONFLICT(entity_id) DO UPDATE SET
                    entity_type = excluded.entity_type,
                    display_name = COALESCE(excluded.display_name, nodes.display_name),
                    username = COALESCE(excluded.username, nodes.username),
                    metadata = COALESCE(excluded.metadata, nodes.metadata),
                    last_interaction_at = MAX(nodes.last_interaction_at, excluded.last_interaction_at),
                    first_seen_at = CASE
                        WHEN nodes.first_seen_at = 0 THEN excluded.first_seen_at
                        WHEN excluded.first_seen_at = 0 THEN nodes.first_seen_at
                        ELSE MIN(nodes.first_seen_at, excluded.first_seen_at)
                    END
                """,
            arguments: [
                entityId,
                entityType,
                displayName,
                username,
                AppConstants.Graph.defaultCategory,
                AppConstants.Graph.automaticCategorySource,
                lastInteractionAt?.timeIntervalSince1970 ?? 0,
                firstSeenAt?.timeIntervalSince1970 ?? 0,
                metadata
            ]
        )
    }

    private static func upsertEdge(
        in db: Database,
        source: Int64,
        target: Int64,
        edgeType: String,
        contextChatId: Int64?,
        weight: Double,
        messageCount: Int,
        lastActiveAt: Date?
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO edges (
                    source_id,
                    target_id,
                    edge_type,
                    weight,
                    message_count,
                    last_active_at,
                    context_chat_id
                )
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(source_id, target_id, edge_type, context_chat_id) DO UPDATE SET
                    weight = MAX(edges.weight, excluded.weight),
                    message_count = MAX(edges.message_count, excluded.message_count),
                    last_active_at = MAX(edges.last_active_at, excluded.last_active_at)
                """,
            arguments: [
                source,
                target,
                edgeType,
                weight,
                messageCount,
                lastActiveAt?.timeIntervalSince1970 ?? 0,
                contextChatId
            ]
        )
    }
}
