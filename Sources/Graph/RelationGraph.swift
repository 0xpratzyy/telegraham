import Foundation
import GRDB

actor RelationGraph {
    static let shared = RelationGraph()

    struct Node: Sendable, Equatable, Hashable {
        let entityId: Int64
        let entityType: String
        let displayName: String?
        let username: String?
        let category: String
        let categorySource: String
        let interactionScore: Double
        let lastInteractionAt: Date?
        let firstSeenAt: Date?
        let metadata: String?
    }

    struct Edge: Sendable, Equatable, Hashable {
        let id: Int64
        let sourceId: Int64
        let targetId: Int64
        let edgeType: String
        let weight: Double
        let messageCount: Int
        let lastActiveAt: Date?
        let contextChatId: Int64?
    }

    func upsertNode(entityId: Int64, type: String, name: String?, username: String?) async {
        let now = Date().timeIntervalSince1970

        do {
            try await DatabaseManager.shared.write { db in
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
                        VALUES (?, ?, ?, ?, ?, ?, 0, 0, ?, NULL)
                        ON CONFLICT(entity_id) DO UPDATE SET
                            entity_type = excluded.entity_type,
                            display_name = COALESCE(excluded.display_name, nodes.display_name),
                            username = COALESCE(excluded.username, nodes.username)
                        """,
                    arguments: [
                        entityId,
                        type,
                        name,
                        username,
                        AppConstants.Graph.defaultCategory,
                        AppConstants.Graph.automaticCategorySource,
                        now
                    ]
                )
            }
        } catch {
            print("[RelationGraph] Failed to upsert node \(entityId): \(error)")
        }
    }

    func setCategory(entityId: Int64, category: String, source: String) async {
        do {
            try await DatabaseManager.shared.write { db in
                try db.execute(
                    sql: """
                        UPDATE nodes
                        SET category = ?, category_source = ?
                        WHERE entity_id = ?
                        """,
                    arguments: [category, source, entityId]
                )
            }
        } catch {
            print("[RelationGraph] Failed to set category for node \(entityId): \(error)")
        }
    }

    func getNode(entityId: Int64) async -> Node? {
        do {
            return try await DatabaseManager.shared.read { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT entity_id, entity_type, display_name, username, category, category_source,
                               interaction_score, last_interaction_at, first_seen_at, metadata
                        FROM nodes
                        WHERE entity_id = ?
                        """,
                    arguments: [entityId]
                ) else {
                    return nil
                }

                return Self.node(from: row)
            }
        } catch {
            print("[RelationGraph] Failed to fetch node \(entityId): \(error)")
            return nil
        }
    }

    func upsertEdge(source: Int64, target: Int64, type: String, contextChatId: Int64?) async {
        let now = Date().timeIntervalSince1970

        do {
            try await DatabaseManager.shared.write { db in
                if let edgeId = try Self.edgeId(
                    in: db,
                    source: source,
                    target: target,
                    type: type,
                    contextChatId: contextChatId
                ) {
                    try db.execute(
                        sql: """
                            UPDATE edges
                            SET last_active_at = MAX(last_active_at, ?)
                            WHERE id = ?
                            """,
                        arguments: [now, edgeId]
                    )
                } else {
                    try Self.insertEdge(
                        in: db,
                        source: source,
                        target: target,
                        type: type,
                        contextChatId: contextChatId,
                        weight: 1,
                        messageCount: 0,
                        lastActiveAt: now
                    )
                }

                try Self.refreshNodeStats(in: db, entityIds: [source, target])
            }
        } catch {
            print("[RelationGraph] Failed to upsert edge \(source)->\(target) [\(type)]: \(error)")
        }
    }

    func incrementEdge(source: Int64, target: Int64, type: String, contextChatId: Int64?) async {
        let now = Date().timeIntervalSince1970

        do {
            try await DatabaseManager.shared.write { db in
                if let edgeId = try Self.edgeId(
                    in: db,
                    source: source,
                    target: target,
                    type: type,
                    contextChatId: contextChatId
                ) {
                    try db.execute(
                        sql: """
                            UPDATE edges
                            SET weight = weight + 1,
                                message_count = message_count + 1,
                                last_active_at = MAX(last_active_at, ?)
                            WHERE id = ?
                            """,
                        arguments: [now, edgeId]
                    )
                } else {
                    try Self.insertEdge(
                        in: db,
                        source: source,
                        target: target,
                        type: type,
                        contextChatId: contextChatId,
                        weight: 1,
                        messageCount: 1,
                        lastActiveAt: now
                    )
                }

                try Self.refreshNodeStats(in: db, entityIds: [source, target])
            }
        } catch {
            print("[RelationGraph] Failed to increment edge \(source)->\(target) [\(type)]: \(error)")
        }
    }

    func topContacts(category: String?, limit: Int) async -> [Node] {
        do {
            return try await DatabaseManager.shared.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT entity_id, entity_type, display_name, username, category, category_source,
                               interaction_score, last_interaction_at, first_seen_at, metadata
                        FROM nodes
                        WHERE entity_type = 'user'
                          AND (? IS NULL OR category = ?)
                        ORDER BY interaction_score DESC, last_interaction_at DESC, COALESCE(display_name, username, '') COLLATE NOCASE ASC
                        LIMIT ?
                        """,
                    arguments: [category, category, limit]
                )

                return rows.map(Self.node(from:))
            }
        } catch {
            print("[RelationGraph] Failed to fetch top contacts: \(error)")
            return []
        }
    }

    func connections(for entityId: Int64, hops: Int) async -> [Node] {
        guard hops > 0 else { return [] }

        do {
            return try await DatabaseManager.shared.read { db in
                var visited: Set<Int64> = [entityId]
                var frontier: Set<Int64> = [entityId]

                for _ in 0..<hops {
                    guard !frontier.isEmpty else { break }

                    let edges = try Self.fetchEdgesTouching(db: db, entityIds: Array(frontier))
                    var next: Set<Int64> = []

                    for edge in edges {
                        if !visited.contains(edge.sourceId) {
                            next.insert(edge.sourceId)
                        }
                        if !visited.contains(edge.targetId) {
                            next.insert(edge.targetId)
                        }
                    }

                    guard !next.isEmpty else { break }
                    visited.formUnion(next)
                    frontier = next
                }

                let connectedIds = visited.subtracting([entityId])
                guard !connectedIds.isEmpty else { return [] }

                return try Self.fetchNodes(db: db, entityIds: Array(connectedIds))
                    .sorted(by: Self.sortNodesForConnections)
            }
        } catch {
            print("[RelationGraph] Failed to fetch connections for node \(entityId): \(error)")
            return []
        }
    }

    func staleContacts(olderThan: TimeInterval, category: String?) async -> [Node] {
        let cutoff = Date().addingTimeInterval(-olderThan).timeIntervalSince1970

        do {
            return try await DatabaseManager.shared.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT entity_id, entity_type, display_name, username, category, category_source,
                               interaction_score, last_interaction_at, first_seen_at, metadata
                        FROM nodes
                        WHERE entity_type = 'user'
                          AND (? IS NULL OR category = ?)
                          AND (last_interaction_at = 0 OR last_interaction_at <= ?)
                        ORDER BY interaction_score DESC, last_interaction_at ASC, COALESCE(display_name, username, '') COLLATE NOCASE ASC
                        """,
                    arguments: [category, category, cutoff]
                )

                return rows.map(Self.node(from:))
            }
        } catch {
            print("[RelationGraph] Failed to fetch stale contacts: \(error)")
            return []
        }
    }

    func contactsByCategory() async -> [String: [Node]] {
        do {
            return try await DatabaseManager.shared.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT entity_id, entity_type, display_name, username, category, category_source,
                               interaction_score, last_interaction_at, first_seen_at, metadata
                        FROM nodes
                        WHERE entity_type = 'user'
                        ORDER BY category COLLATE NOCASE ASC,
                                 interaction_score DESC,
                                 last_interaction_at DESC,
                                 COALESCE(display_name, username, '') COLLATE NOCASE ASC
                        """
                )

                return rows.reduce(into: [String: [Node]]()) { grouped, row in
                    let node = Self.node(from: row)
                    grouped[node.category, default: []].append(node)
                }
            }
        } catch {
            print("[RelationGraph] Failed to group contacts by category: \(error)")
            return [:]
        }
    }

    func recalculateScores() async {
        do {
            try await DatabaseManager.shared.write { db in
                try Self.refreshAllNodeStats(in: db)
            }
        } catch {
            print("[RelationGraph] Failed to recalculate scores: \(error)")
        }
    }

    private static func insertEdge(
        in db: Database,
        source: Int64,
        target: Int64,
        type: String,
        contextChatId: Int64?,
        weight: Double,
        messageCount: Int,
        lastActiveAt: TimeInterval
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
                """,
            arguments: [
                source,
                target,
                type,
                weight,
                messageCount,
                lastActiveAt,
                contextChatId
            ]
        )
    }

    private static func edgeId(
        in db: Database,
        source: Int64,
        target: Int64,
        type: String,
        contextChatId: Int64?
    ) throws -> Int64? {
        try Int64.fetchOne(
            db,
            sql: """
                SELECT id
                FROM edges
                WHERE source_id = ?
                  AND target_id = ?
                  AND edge_type = ?
                  AND (
                        (context_chat_id IS NULL AND ? IS NULL)
                     OR context_chat_id = ?
                  )
                LIMIT 1
                """,
            arguments: [source, target, type, contextChatId, contextChatId]
        )
    }

    private static func refreshNodeStats(in db: Database, entityIds: [Int64]) throws {
        let uniqueIds = Array(Set(entityIds))
        guard !uniqueIds.isEmpty else { return }

        let placeholders = Array(repeating: "?", count: uniqueIds.count).joined(separator: ", ")
        var arguments = StatementArguments()
        for entityId in uniqueIds {
            arguments += [entityId]
        }

        try db.execute(
            sql: """
                UPDATE nodes
                SET interaction_score = COALESCE(
                        (
                            SELECT SUM(weight + message_count)
                            FROM edges
                            WHERE source_id = nodes.entity_id OR target_id = nodes.entity_id
                        ),
                        0
                    ),
                    last_interaction_at = COALESCE(
                        (
                            SELECT MAX(last_active_at)
                            FROM edges
                            WHERE source_id = nodes.entity_id OR target_id = nodes.entity_id
                        ),
                        0
                    )
                WHERE entity_id IN (\(placeholders))
                """,
            arguments: arguments
        )
    }

    private static func refreshAllNodeStats(in db: Database) throws {
        try db.execute(
            sql: """
                UPDATE nodes
                SET interaction_score = COALESCE(
                        (
                            SELECT SUM(weight + message_count)
                            FROM edges
                            WHERE source_id = nodes.entity_id OR target_id = nodes.entity_id
                        ),
                        0
                    ),
                    last_interaction_at = COALESCE(
                        (
                            SELECT MAX(last_active_at)
                            FROM edges
                            WHERE source_id = nodes.entity_id OR target_id = nodes.entity_id
                        ),
                        0
                    )
                """
        )
    }

    private static func fetchEdgesTouching(db: Database, entityIds: [Int64]) throws -> [Edge] {
        guard !entityIds.isEmpty else { return [] }

        let placeholders = Array(repeating: "?", count: entityIds.count).joined(separator: ", ")
        var arguments = StatementArguments()
        for entityId in entityIds {
            arguments += [entityId]
        }
        for entityId in entityIds {
            arguments += [entityId]
        }

        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, source_id, target_id, edge_type, weight, message_count, last_active_at, context_chat_id
                FROM edges
                WHERE source_id IN (\(placeholders))
                   OR target_id IN (\(placeholders))
                ORDER BY last_active_at DESC, weight DESC
                """,
            arguments: arguments
        )

        return rows.map(Self.edge(from:))
    }

    private static func fetchNodes(db: Database, entityIds: [Int64]) throws -> [Node] {
        guard !entityIds.isEmpty else { return [] }

        let placeholders = Array(repeating: "?", count: entityIds.count).joined(separator: ", ")
        var arguments = StatementArguments()
        for entityId in entityIds {
            arguments += [entityId]
        }

        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT entity_id, entity_type, display_name, username, category, category_source,
                       interaction_score, last_interaction_at, first_seen_at, metadata
                FROM nodes
                WHERE entity_id IN (\(placeholders))
                """,
            arguments: arguments
        )

        return rows.map(Self.node(from:))
    }

    private static func node(from row: Row) -> Node {
        let lastInteractionAt = row["last_interaction_at"] as Double
        let firstSeenAt = row["first_seen_at"] as Double

        return Node(
            entityId: row["entity_id"],
            entityType: row["entity_type"],
            displayName: row["display_name"],
            username: row["username"],
            category: row["category"],
            categorySource: row["category_source"],
            interactionScore: row["interaction_score"],
            lastInteractionAt: lastInteractionAt > 0 ? Date(timeIntervalSince1970: lastInteractionAt) : nil,
            firstSeenAt: firstSeenAt > 0 ? Date(timeIntervalSince1970: firstSeenAt) : nil,
            metadata: row["metadata"]
        )
    }

    private static func edge(from row: Row) -> Edge {
        let lastActiveAt = row["last_active_at"] as Double

        return Edge(
            id: row["id"],
            sourceId: row["source_id"],
            targetId: row["target_id"],
            edgeType: row["edge_type"],
            weight: row["weight"],
            messageCount: row["message_count"],
            lastActiveAt: lastActiveAt > 0 ? Date(timeIntervalSince1970: lastActiveAt) : nil,
            contextChatId: row["context_chat_id"]
        )
    }

    private static func sortNodesForConnections(lhs: Node, rhs: Node) -> Bool {
        if lhs.interactionScore != rhs.interactionScore {
            return lhs.interactionScore > rhs.interactionScore
        }

        switch (lhs.lastInteractionAt, rhs.lastInteractionAt) {
        case let (left?, right?) where left != right:
            return left > right
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        default:
            let leftName = lhs.displayName ?? lhs.username ?? ""
            let rightName = rhs.displayName ?? rhs.username ?? ""
            return leftName.localizedCaseInsensitiveCompare(rightName) == .orderedAscending
        }
    }
}
