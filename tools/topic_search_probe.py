#!/usr/bin/env python3
import argparse
import json
import sqlite3
from collections import defaultdict
from pathlib import Path
from typing import Any


DEFAULT_DB = Path.home() / "Library" / "Application Support" / "Pidgy" / "pidgy.db"


def normalized_fts_query(query: str) -> str:
    sanitized = query.replace('"', " ")
    tokens = [token for token in sanitized.split() if token]
    return " ".join(f'"{token}"' for token in tokens)


def query_rows(conn: sqlite3.Connection, sql: str, params: tuple[Any, ...]) -> list[dict[str, Any]]:
    conn.row_factory = sqlite3.Row
    rows = conn.execute(sql, params).fetchall()
    return [dict(row) for row in rows]


def main() -> int:
    parser = argparse.ArgumentParser(description="Probe local FTS evidence for topic-search queries.")
    parser.add_argument("query", help="Topic query to probe, e.g. 'first dollar'")
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--limit", type=int, default=20)
    args = parser.parse_args()

    if not args.db.exists():
        raise SystemExit(f"DB not found: {args.db}")

    fts_query = normalized_fts_query(args.query)
    if not fts_query:
        raise SystemExit("Query is empty after FTS normalization")

    with sqlite3.connect(args.db) as conn:
        message_hits = query_rows(
            conn,
            """
            SELECT
              m.chat_id,
              m.sender_name,
              m.is_outgoing,
              m.date,
              substr(coalesce(m.text_content,''),1,220) AS snippet,
              (-bm25(messages_fts)) AS score
            FROM messages_fts
            JOIN messages AS m ON m.rowid = messages_fts.rowid
            WHERE messages_fts MATCH ?
            ORDER BY score DESC, m.date DESC, m.id DESC
            LIMIT ?
            """,
            (fts_query, args.limit),
        )

        chat_buckets: dict[int, dict[str, Any]] = defaultdict(
            lambda: {"chat_id": 0, "hit_count": 0, "best_score": 0.0, "latest_date": 0.0}
        )
        for hit in message_hits:
            chat_id = int(hit["chat_id"])
            bucket = chat_buckets[chat_id]
            bucket["chat_id"] = chat_id
            bucket["hit_count"] += 1
            bucket["best_score"] = max(float(bucket["best_score"]), float(hit["score"]))
            bucket["latest_date"] = max(float(bucket["latest_date"]), float(hit["date"]))

        chat_rollup = sorted(
            chat_buckets.values(),
            key=lambda item: (-float(item["best_score"]), -float(item["latest_date"])),
        )[: args.limit]

    report = {
        "query": args.query,
        "ftsQuery": fts_query,
        "messageHitCount": len(message_hits),
        "chatRollupCount": len(chat_rollup),
        "messageHits": message_hits,
        "chatRollup": chat_rollup,
    }
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
