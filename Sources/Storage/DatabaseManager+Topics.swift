// DatabaseManager+Topics.swift
// Dashboard topics: list, manual add, delete.

import Foundation
import GRDB

extension DatabaseManager {
    private static let manualDashboardTopicScore = 10_000.0

    func loadDashboardTopics(limit: Int = AppConstants.Dashboard.maxTopicCount) async -> [DashboardTopic] {
        guard let pool = await ensureDatabase() else { return [] }

        do {
            return try await pool.read { db in
                try Self.loadDashboardTopics(in: db, limit: limit)
            }
        } catch {
            print("[DatabaseManager] Failed to load dashboard topics: \(error)")
            return []
        }
    }

    func addDashboardTopic(name rawName: String, rationale rawRationale: String = "Added manually.") async -> DashboardTopic? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.lowercased() != "uncategorized" else { return nil }
        guard let pool = await ensureDatabase() else { return nil }

        let rationale = rawRationale.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            return try await pool.write { db in
                let now = Date().timeIntervalSince1970
                let pinnedRank = try Int.fetchOne(
                    db,
                    sql: "SELECT COALESCE(MIN(rank), 0) - 1 FROM dashboard_topics"
                ) ?? -1

                try db.execute(
                    sql: """
                        INSERT INTO dashboard_topics (name, rationale, score, rank, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(name) DO UPDATE SET
                            rationale = CASE
                                WHEN excluded.rationale != '' THEN excluded.rationale
                                ELSE dashboard_topics.rationale
                            END,
                            score = MAX(dashboard_topics.score, excluded.score),
                            rank = MIN(dashboard_topics.rank, excluded.rank),
                            updated_at = excluded.updated_at
                        """,
                    arguments: [
                        name,
                        rationale,
                        Self.manualDashboardTopicScore,
                        pinnedRank,
                        now,
                        now
                    ]
                )

                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT id, name, rationale, score, rank, created_at, updated_at
                        FROM dashboard_topics
                        WHERE name = ? COLLATE NOCASE
                        """,
                    arguments: [name]
                ) else {
                    return nil
                }
                return Self.dashboardTopic(from: row)
            }
        } catch {
            print("[DatabaseManager] Failed to add dashboard topic \(name): \(error)")
            return nil
        }
    }

    /// Hard-deletes a dashboard topic. The Tasks page's per-task topic
    /// label survives because tasks store the topic name (not id), but
    /// the sidebar entry disappears and won't be re-discovered until the
    /// user explicitly runs topic discovery again.
    func deleteDashboardTopic(id: Int64) async {
        guard let pool = await ensureDatabase() else { return }
        do {
            try await pool.write { db in
                try db.execute(
                    sql: "DELETE FROM dashboard_topics WHERE id = ?",
                    arguments: [id]
                )
            }
        } catch {
            print("[DatabaseManager] Failed to delete dashboard topic \(id): \(error)")
        }
    }

    private static func loadDashboardTopics(in db: Database, limit: Int) throws -> [DashboardTopic] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, name, rationale, score, rank, created_at, updated_at
                FROM dashboard_topics
                ORDER BY rank ASC, score DESC, name COLLATE NOCASE ASC
                LIMIT ?
                """,
            arguments: [limit]
        )
        return rows.map(dashboardTopic(from:))
    }

    private static func dashboardTopic(from row: Row) -> DashboardTopic {
        let createdAtSeconds: Double = row["created_at"]
        let updatedAtSeconds: Double = row["updated_at"]
        return DashboardTopic(
            id: row["id"],
            name: row["name"],
            rationale: row["rationale"],
            score: row["score"],
            rank: row["rank"],
            createdAt: Date(timeIntervalSince1970: createdAtSeconds),
            updatedAt: Date(timeIntervalSince1970: updatedAtSeconds)
        )
    }
}
