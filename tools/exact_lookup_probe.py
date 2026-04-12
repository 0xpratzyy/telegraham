#!/usr/bin/env python3
import argparse
import json
import re
import sqlite3
from pathlib import Path
from typing import Any


DEFAULT_DB = Path.home() / "Library" / "Application Support" / "Pidgy" / "pidgy.db"

ARTIFACT_KEYWORDS = {
    "wallet", "address", "contract", "hash", "link", "url", "domain", "handle", "username",
    "email", "repo", "gist", "meet", "github", "youtube", "tx"
}
STOP_WORDS = {
    "where", "did", "the", "with", "this", "that", "have", "from", "into", "for",
    "sent", "shared", "paste", "pasted", "posted", "show", "find", "message", "messages",
    "chat", "chats", "my", "i", "a", "an", "to"
}
RECIPIENT_STOP_WORDS = STOP_WORDS | {
    "send", "sent", "share", "shared", "paste", "pasted", "post", "posted",
    "only", "here", "there", "address", "wallet", "contract", "hash", "link", "url", "doc", "docs"
}


def normalize(text: str) -> str:
    return re.sub(r"\s+", " ", text.strip().lower())


def structured_tokens(text: str) -> list[str]:
    patterns = [
        r"\b[A-Za-z0-9._%+-]+@(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}\b",
        r"https?://[^\s]+",
        r"\b(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}/[^\s]+",
        r"0x[a-fA-F0-9]{8,}",
        r"@[A-Za-z0-9_]{3,}",
        r"\b[a-z]{3}-[a-z]{4}-[a-z]{3}\b",
        r"\b[1-9A-HJ-NP-Za-km-z]{24,64}\b",
        r"\b(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}\b",
    ]
    found: list[str] = []
    ranges: list[tuple[int, int]] = []
    for pattern in patterns:
        for match in re.finditer(pattern, text):
            start, end = match.span()
            if any(start >= existing_start and end <= existing_end for existing_start, existing_end in ranges):
                continue
            found.append(match.group(0))
            ranges.append((start, end))
    deduped: list[str] = []
    seen = set()
    for token in found:
        lowered = token.lower()
        if lowered in seen:
            continue
        seen.add(lowered)
        deduped.append(token)
    return deduped


def extract_recipient_keywords(normalized_query: str) -> list[str]:
    cleaned_query = re.sub(r"[?!.:,;]+$", "", normalized_query).strip()
    patterns = [
        r"\b(?:send|share|paste|post)\s+(?:to|with)\s+([a-z0-9_@.\- ]+)$",
        r"\b(?:sent|shared|pasted|posted)\s+(?:to|with)\s+([a-z0-9_@.\- ]+)$",
        r"\b(?:to|with)\s+([a-z0-9_@.\- ]+)$",
    ]
    for pattern in patterns:
        match = re.search(pattern, cleaned_query)
        if not match:
            continue
        extracted = [
            token
            for token in re.split(r"[^a-z0-9@.]+", match.group(1))
            if token
            and token not in RECIPIENT_STOP_WORDS
            and token not in ARTIFACT_KEYWORDS
            and not token.isdigit()
        ]
        if extracted:
            return list(dict.fromkeys(extracted))
    return []


def artifact_keywords_from_query(normalized_query: str) -> list[str]:
    tokens = re.split(r"[^a-z0-9@.]+", normalized_query)
    return [token for token in tokens if token in ARTIFACT_KEYWORDS]


def query_messages(conn: sqlite3.Connection, sql: str, params: tuple[Any, ...] = ()) -> list[dict[str, Any]]:
    conn.row_factory = sqlite3.Row
    rows = conn.execute(sql, params).fetchall()
    return [dict(row) for row in rows]


def main() -> int:
    parser = argparse.ArgumentParser(description="Probe local SQLite evidence for an exact artifact lookup before promoting behavior into product.")
    parser.add_argument("query", help="User query to probe, e.g. 'wallet I sent to Rahul'")
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--limit", type=int, default=10)
    args = parser.parse_args()

    if not args.db.exists():
        raise SystemExit(f"DB not found: {args.db}")

    normalized_query = normalize(args.query)
    recipients = extract_recipient_keywords(normalized_query)
    artifact_keywords = artifact_keywords_from_query(normalized_query)
    exact_tokens = structured_tokens(args.query)

    artifact_sql_clauses: list[str] = []
    artifact_params: list[Any] = []
    for token in artifact_keywords:
        artifact_sql_clauses.append("lower(coalesce(text_content,'')) like ?")
        artifact_params.append(f"%{token}%")
    for token in exact_tokens:
        artifact_sql_clauses.append("lower(coalesce(text_content,'')) like ?")
        artifact_params.append(f"%{token.lower()}%")

    artifact_where = " OR ".join(artifact_sql_clauses) if artifact_sql_clauses else "0"
    recipient_where = " OR ".join(["lower(coalesce(text_content,'')) like ?" for _ in recipients]) if recipients else "0"
    recipient_params = [f"%{recipient}%" for recipient in recipients]

    with sqlite3.connect(args.db) as conn:
        artifact_hits = query_messages(
            conn,
            f"""
            select chat_id, sender_name, is_outgoing, date, substr(coalesce(text_content,''),1,220) as snippet
            from messages
            where {artifact_where}
            order by date desc
            limit ?
            """,
            tuple(artifact_params + [args.limit]),
        ) if artifact_sql_clauses else []

        recipient_hits = query_messages(
            conn,
            f"""
            select chat_id, sender_name, is_outgoing, date, substr(coalesce(text_content,''),1,220) as snippet
            from messages
            where {recipient_where}
            order by date desc
            limit ?
            """,
            tuple(recipient_params + [args.limit]),
        ) if recipients else []

        overlap_hits = query_messages(
            conn,
            f"""
            select chat_id, sender_name, is_outgoing, date, substr(coalesce(text_content,''),1,220) as snippet
            from messages
            where ({artifact_where}) and ({recipient_where})
            order by date desc
            limit ?
            """,
            tuple(artifact_params + recipient_params + [args.limit]),
        ) if artifact_sql_clauses and recipients else []

        same_chat_overlap = query_messages(
            conn,
            f"""
            with artifact_chats as (
              select distinct chat_id from messages where {artifact_where}
            ),
            recipient_chats as (
              select distinct chat_id from messages where {recipient_where}
            )
            select m.chat_id,
                   max(m.date) as latest_date,
                   sum(case when ({artifact_where}) then 1 else 0 end) as artifact_messages,
                   sum(case when ({recipient_where}) then 1 else 0 end) as recipient_messages
            from messages m
            where m.chat_id in (
              select chat_id from artifact_chats
              intersect
              select chat_id from recipient_chats
            )
            group by m.chat_id
            order by latest_date desc
            limit ?
            """,
            tuple(artifact_params + recipient_params + artifact_params + recipient_params + [args.limit]),
        ) if artifact_sql_clauses and recipients else []

    report = {
        "query": args.query,
        "normalizedQuery": normalized_query,
        "artifactKeywords": artifact_keywords,
        "exactTokens": exact_tokens,
        "recipientKeywords": recipients,
        "artifactHitCount": len(artifact_hits),
        "recipientHitCount": len(recipient_hits),
        "directArtifactAndRecipientHitCount": len(overlap_hits),
        "sameChatArtifactAndRecipientOverlapCount": len(same_chat_overlap),
        "artifactHits": artifact_hits,
        "recipientHits": recipient_hits,
        "directArtifactAndRecipientHits": overlap_hits,
        "sameChatArtifactAndRecipientOverlap": same_chat_overlap,
    }

    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
