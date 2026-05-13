import GRDB

enum PidgyMigrations {
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_foundation") { db in
            try db.execute(sql: """
                CREATE TABLE messages (
                    id INTEGER NOT NULL,
                    chat_id INTEGER NOT NULL,
                    sender_user_id INTEGER,
                    sender_name TEXT,
                    date REAL NOT NULL,
                    text_content TEXT,
                    media_type TEXT,
                    is_outgoing INTEGER DEFAULT 0,
                    PRIMARY KEY (id, chat_id)
                )
                """)

            try db.execute(sql: """
                CREATE INDEX idx_messages_chat_date
                ON messages(chat_id, date DESC)
                """)

            try db.execute(sql: """
                CREATE VIRTUAL TABLE messages_fts USING fts5(
                    text_content,
                    content=messages,
                    content_rowid=rowid
                )
                """)

            try db.execute(sql: """
                CREATE TRIGGER messages_ai AFTER INSERT ON messages BEGIN
                    INSERT INTO messages_fts(rowid, text_content)
                    VALUES (new.rowid, new.text_content);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER messages_ad AFTER DELETE ON messages BEGIN
                    INSERT INTO messages_fts(messages_fts, rowid, text_content)
                    VALUES ('delete', old.rowid, old.text_content);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER messages_au AFTER UPDATE ON messages BEGIN
                    INSERT INTO messages_fts(messages_fts, rowid, text_content)
                    VALUES ('delete', old.rowid, old.text_content);
                    INSERT INTO messages_fts(rowid, text_content)
                    VALUES (new.rowid, new.text_content);
                END
                """)

            try db.execute(sql: """
                CREATE TABLE pipeline_cache (
                    chat_id INTEGER PRIMARY KEY,
                    category TEXT NOT NULL,
                    suggested_action TEXT NOT NULL DEFAULT '',
                    last_message_id INTEGER NOT NULL,
                    analyzed_at REAL NOT NULL
                )
                """)

            try db.execute(sql: """
                CREATE TABLE ai_usage (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    provider TEXT NOT NULL,
                    model TEXT NOT NULL,
                    input_tokens INTEGER NOT NULL,
                    output_tokens INTEGER NOT NULL,
                    timestamp REAL NOT NULL
                )
                """)

            try db.execute(sql: """
                CREATE TABLE sync_state (
                    chat_id INTEGER PRIMARY KEY,
                    last_indexed_message_id INTEGER DEFAULT 0,
                    last_indexed_at REAL DEFAULT 0,
                    total_messages_indexed INTEGER DEFAULT 0
                )
                """)
        }

        migrator.registerMigration("v2_relation_graph") { db in
            try db.execute(sql: """
                CREATE TABLE nodes (
                    entity_id INTEGER PRIMARY KEY,
                    entity_type TEXT NOT NULL,
                    display_name TEXT,
                    username TEXT,
                    category TEXT DEFAULT '\(AppConstants.Graph.defaultCategory)',
                    category_source TEXT DEFAULT '\(AppConstants.Graph.automaticCategorySource)',
                    interaction_score REAL DEFAULT 0,
                    last_interaction_at REAL DEFAULT 0,
                    first_seen_at REAL DEFAULT 0,
                    metadata TEXT
                )
                """)

            try db.execute(sql: """
                CREATE INDEX idx_nodes_category
                ON nodes(category)
                """)

            try db.execute(sql: """
                CREATE INDEX idx_nodes_score
                ON nodes(interaction_score DESC)
                """)

            try db.execute(sql: """
                CREATE TABLE edges (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    source_id INTEGER NOT NULL REFERENCES nodes(entity_id),
                    target_id INTEGER NOT NULL REFERENCES nodes(entity_id),
                    edge_type TEXT NOT NULL,
                    weight REAL DEFAULT 1.0,
                    message_count INTEGER DEFAULT 0,
                    last_active_at REAL DEFAULT 0,
                    context_chat_id INTEGER,
                    UNIQUE(source_id, target_id, edge_type, context_chat_id)
                )
                """)

            try db.execute(sql: """
                CREATE INDEX idx_edges_source
                ON edges(source_id, last_active_at DESC)
                """)

            try db.execute(sql: """
                CREATE INDEX idx_edges_target
                ON edges(target_id, last_active_at DESC)
                """)
        }

        migrator.registerMigration("v3_sync_state_search_ready") { db in
            try db.execute(sql: """
                ALTER TABLE sync_state
                ADD COLUMN is_search_ready INTEGER NOT NULL DEFAULT 0
                """)
        }

        migrator.registerMigration("v4_embeddings") { db in
            try db.execute(sql: """
                CREATE TABLE embeddings (
                    message_id INTEGER NOT NULL,
                    chat_id INTEGER NOT NULL,
                    vector BLOB NOT NULL,
                    text_preview TEXT,
                    PRIMARY KEY (message_id, chat_id),
                    FOREIGN KEY (message_id, chat_id) REFERENCES messages(id, chat_id)
                )
                """)

            try db.execute(sql: """
                CREATE INDEX idx_embeddings_chat
                ON embeddings(chat_id)
                """)
        }

        migrator.registerMigration("v5_storage_hygiene") { db in
            try db.execute(sql: """
                CREATE INDEX idx_messages_sender
                ON messages(sender_user_id)
                """)

            try db.execute(sql: """
                ALTER TABLE embeddings RENAME TO embeddings_legacy
                """)

            try db.execute(sql: """
                CREATE TABLE embeddings (
                    message_id INTEGER NOT NULL,
                    chat_id INTEGER NOT NULL,
                    vector BLOB NOT NULL,
                    text_preview TEXT,
                    PRIMARY KEY (message_id, chat_id),
                    FOREIGN KEY (message_id, chat_id) REFERENCES messages(id, chat_id) ON DELETE CASCADE
                )
                """)

            try db.execute(sql: """
                INSERT INTO embeddings (message_id, chat_id, vector, text_preview)
                SELECT message_id, chat_id, vector, text_preview
                FROM embeddings_legacy
                """)

            try db.execute(sql: """
                DROP TABLE embeddings_legacy
                """)

            try db.execute(sql: """
                CREATE INDEX idx_embeddings_chat
                ON embeddings(chat_id)
                """)
        }

        migrator.registerMigration("v6_recent_sync_state") { db in
            try db.execute(sql: """
                CREATE TABLE recent_sync_state (
                    chat_id INTEGER PRIMARY KEY,
                    latest_synced_message_id INTEGER NOT NULL DEFAULT 0,
                    last_recent_sync_at REAL NOT NULL DEFAULT 0
                )
                """)
        }

        migrator.registerMigration("v7_pipeline_cache_schema_version") { db in
            try db.execute(sql: """
                ALTER TABLE pipeline_cache
                ADD COLUMN schema_version INTEGER NOT NULL DEFAULT 1
                """)
        }

        migrator.registerMigration("v8_dashboard_tasks") { db in
            try db.execute(sql: """
                CREATE TABLE dashboard_topics (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL UNIQUE COLLATE NOCASE,
                    rationale TEXT NOT NULL DEFAULT '',
                    score REAL NOT NULL DEFAULT 0,
                    rank INTEGER NOT NULL DEFAULT 0,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                )
                """)

            try db.execute(sql: """
                CREATE INDEX idx_dashboard_topics_rank
                ON dashboard_topics(rank ASC, score DESC)
                """)

            try db.execute(sql: """
                CREATE TABLE dashboard_tasks (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    stable_fingerprint TEXT NOT NULL UNIQUE,
                    title TEXT NOT NULL,
                    summary TEXT NOT NULL DEFAULT '',
                    suggested_action TEXT NOT NULL DEFAULT '',
                    owner_name TEXT NOT NULL DEFAULT '',
                    person_name TEXT NOT NULL DEFAULT '',
                    chat_id INTEGER NOT NULL,
                    chat_title TEXT NOT NULL DEFAULT '',
                    topic_id INTEGER REFERENCES dashboard_topics(id) ON DELETE SET NULL,
                    topic_name TEXT,
                    priority TEXT NOT NULL DEFAULT 'medium',
                    status TEXT NOT NULL DEFAULT 'open',
                    confidence REAL NOT NULL DEFAULT 0,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    due_at REAL,
                    snoozed_until REAL,
                    latest_source_date REAL
                )
                """)

            try db.execute(sql: """
                CREATE INDEX idx_dashboard_tasks_status
                ON dashboard_tasks(status, priority, updated_at DESC)
                """)

            try db.execute(sql: """
                CREATE INDEX idx_dashboard_tasks_topic
                ON dashboard_tasks(topic_id, status, updated_at DESC)
                """)

            try db.execute(sql: """
                CREATE INDEX idx_dashboard_tasks_chat
                ON dashboard_tasks(chat_id, status, updated_at DESC)
                """)

            try db.execute(sql: """
                CREATE TABLE dashboard_task_sources (
                    task_id INTEGER NOT NULL REFERENCES dashboard_tasks(id) ON DELETE CASCADE,
                    chat_id INTEGER NOT NULL,
                    message_id INTEGER NOT NULL,
                    sender_name TEXT NOT NULL DEFAULT '',
                    text TEXT NOT NULL DEFAULT '',
                    date REAL NOT NULL,
                    PRIMARY KEY (task_id, chat_id, message_id)
                )
                """)

            try db.execute(sql: """
                CREATE INDEX idx_dashboard_task_sources_message
                ON dashboard_task_sources(chat_id, message_id)
                """)

            try db.execute(sql: """
                CREATE TABLE dashboard_task_sync_state (
                    chat_id INTEGER PRIMARY KEY,
                    latest_message_id INTEGER NOT NULL DEFAULT 0,
                    last_synced_at REAL NOT NULL DEFAULT 0
                )
                """)
        }

        migrator.registerMigration("v9_chat_coverage_state") { db in
            try db.execute(sql: """
                CREATE TABLE chat_coverage_state (
                    chat_id INTEGER PRIMARY KEY,
                    oldest_covered_at REAL,
                    latest_seen_message_id INTEGER NOT NULL DEFAULT 0,
                    last_checked_at REAL NOT NULL DEFAULT 0,
                    is_major INTEGER NOT NULL DEFAULT 0,
                    last_error TEXT
                )
                """)

            try db.execute(sql: """
                CREATE INDEX idx_chat_coverage_major_checked
                ON chat_coverage_state(is_major, last_checked_at DESC)
                """)
        }

        migrator.registerMigration("v10_chat_coverage_state_version") { db in
            try db.execute(sql: """
                ALTER TABLE chat_coverage_state
                ADD COLUMN coverage_version INTEGER NOT NULL DEFAULT 0
                """)
        }

        migrator.registerMigration("v11_chat_coverage_retry_state") { db in
            try db.execute(sql: """
                ALTER TABLE chat_coverage_state
                ADD COLUMN failure_count INTEGER NOT NULL DEFAULT 0
                """)

            try db.execute(sql: """
                ALTER TABLE chat_coverage_state
                ADD COLUMN next_retry_at REAL
                """)

            try db.execute(sql: """
                CREATE INDEX idx_chat_coverage_retry
                ON chat_coverage_state(is_major, next_retry_at, last_checked_at DESC)
                """)
        }

        migrator.registerMigration("v12_chat_coverage_cursor_state") { db in
            try db.execute(sql: """
                ALTER TABLE chat_coverage_state
                ADD COLUMN oldest_covered_message_id INTEGER NOT NULL DEFAULT 0
                """)

            try db.execute(sql: """
                CREATE INDEX idx_chat_coverage_debt
                ON chat_coverage_state(is_major, coverage_version, oldest_covered_at, next_retry_at)
                """)
        }

        migrator.registerMigration("v13_strip_urls_in_fts") { db in
            // Rebuild the FTS triggers to route every message body
            // through `pidgy_strip_urls(...)` before indexing. The raw
            // `text_content` column on `messages` is unchanged — only
            // what FTS sees changes. Display, exports, and the embedding
            // payload all continue to use the original text (the embed
            // path strips URLs on its own).
            //
            // After the trigger swap, drop the existing FTS rows and
            // re-insert them from messages with the stripper applied so
            // historical data isn't stuck on the old noisy index.

            try db.execute(sql: "DROP TRIGGER IF EXISTS messages_ai")
            try db.execute(sql: "DROP TRIGGER IF EXISTS messages_ad")
            try db.execute(sql: "DROP TRIGGER IF EXISTS messages_au")

            try db.execute(sql: """
                CREATE TRIGGER messages_ai AFTER INSERT ON messages BEGIN
                    INSERT INTO messages_fts(rowid, text_content)
                    VALUES (new.rowid, pidgy_strip_urls(new.text_content));
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER messages_ad AFTER DELETE ON messages BEGIN
                    INSERT INTO messages_fts(messages_fts, rowid, text_content)
                    VALUES ('delete', old.rowid, pidgy_strip_urls(old.text_content));
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER messages_au AFTER UPDATE ON messages BEGIN
                    INSERT INTO messages_fts(messages_fts, rowid, text_content)
                    VALUES ('delete', old.rowid, pidgy_strip_urls(old.text_content));
                    INSERT INTO messages_fts(rowid, text_content)
                    VALUES (new.rowid, pidgy_strip_urls(new.text_content));
                END
                """)

            // Reset and rebuild the index. `INSERT INTO messages_fts
            // (messages_fts) VALUES ('delete-all')` clears all rows
            // without touching the underlying messages table.
            try db.execute(sql: """
                INSERT INTO messages_fts(messages_fts) VALUES ('delete-all')
                """)
            try db.execute(sql: """
                INSERT INTO messages_fts(rowid, text_content)
                SELECT rowid, pidgy_strip_urls(text_content)
                FROM messages
                WHERE text_content IS NOT NULL
                """)
        }

        migrator.registerMigration("v14_person_profiles") { db in
            // Compiled-truth profile per Telegram user. Filled lazily on
            // first view in DashboardPersonDetail and refreshed when the
            // observed message count has grown enough since the last
            // extraction. `message_count_at_extraction` lets us decide
            // when the cached profile is worth re-summarizing without
            // firing an AI call on every message.
            try db.execute(sql: """
                CREATE TABLE person_profiles (
                    user_id INTEGER PRIMARY KEY,
                    summary TEXT NOT NULL DEFAULT '',
                    version INTEGER NOT NULL DEFAULT 1,
                    message_count_at_extraction INTEGER NOT NULL DEFAULT 0,
                    last_extracted_at REAL NOT NULL
                )
                """)

            try db.execute(sql: """
                CREATE INDEX idx_person_profiles_last_extracted
                ON person_profiles(last_extracted_at DESC)
                """)
        }

        migrator.registerMigration("v15_repair_dashboard_task_sources_orphans") { db in
            // One-time cleanup for orphaned dashboard_task_sources rows.
            //
            // The FK is `task_id REFERENCES dashboard_tasks(id) ON DELETE
            // CASCADE` (see v8 schema) and `PRAGMA foreign_keys = ON` is
            // set at connection setup, but a PRAGMA foreign_key_check on
            // existing user DBs reports orphans. They predate the FK
            // enforcement OR were written through a code path / migration
            // that bypassed CASCADE — either way the rows are real
            // garbage. Left in place they:
            //   - bloat the `loadDashboardTaskEvidence` UNION queries
            //   - confuse future migrations that try to verify FK health
            //   - make a future PRAGMA foreign_key_check on startup fail
            //     to find a clean baseline
            //
            // Idempotent: zero-orphan DBs delete zero rows.
            try db.execute(sql: """
                DELETE FROM dashboard_task_sources
                WHERE NOT EXISTS (
                    SELECT 1 FROM dashboard_tasks t
                    WHERE t.id = dashboard_task_sources.task_id
                )
                """)
        }

        migrator.registerMigration("v16_messages_sender_date_index_drop_dead_ai_usage") { db in
            // Two pieces of storage hygiene in one migration:
            //
            // 1. Composite (sender_user_id, date DESC) index on messages.
            //    `loadRecentMessages(fromSender:)` filters by
            //    `sender_user_id` and orders by `date DESC, id DESC`. The
            //    existing `idx_messages_sender(sender_user_id)` covers the
            //    filter but not the sort, so once `messages` grows past
            //    ~100k rows SQLite would fall back to a tempfile sort. We
            //    have 11k today; adding the index pre-empts the cliff.
            //
            // 2. Drop the `ai_usage` table. It was declared in v1 but
            //    never received an INSERT or SELECT anywhere in the Swift
            //    sources — usage tracking has lived in `AIUsageStore`
            //    (JSON file on disk) since launch. The dead table just
            //    confuses future maintainers reading the migration log.
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_messages_sender_date
                ON messages(sender_user_id, date DESC)
                """)
            try db.execute(sql: "DROP TABLE IF EXISTS ai_usage")
        }

        return migrator
    }
}
