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

        return migrator
    }
}
