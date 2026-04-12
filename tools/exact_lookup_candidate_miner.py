#!/usr/bin/env python3
import argparse
import json
import re
import sqlite3
from pathlib import Path
from typing import Any

from exact_lookup_probe import DEFAULT_DB


DEFAULT_LIMIT = 80


QUERIES = {
    "urls": """
        select chat_id, id, sender_name, is_outgoing, date, coalesce(text_content,'') as text_content
        from messages
        where is_outgoing = 1 and (
            lower(coalesce(text_content,'')) like '%http://%'
            or lower(coalesce(text_content,'')) like '%https://%'
        )
        order by date desc
        limit ?
    """,
    "handles": """
        select chat_id, id, sender_name, is_outgoing, date, coalesce(text_content,'') as text_content
        from messages
        where is_outgoing = 1 and lower(coalesce(text_content,'')) like '%@%'
        order by date desc
        limit ?
    """,
    "addresses": """
        select chat_id, id, sender_name, is_outgoing, date, coalesce(text_content,'') as text_content
        from messages
        where is_outgoing = 1 and (
            lower(coalesce(text_content,'')) like '%0x%'
            or lower(coalesce(text_content,'')) like '%wallet%'
            or lower(coalesce(text_content,'')) like '%contract%'
            or lower(coalesce(text_content,'')) like '%hash%'
            or lower(coalesce(text_content,'')) like '%@%'
        )
        order by date desc
        limit ?
    """,
}


URL_RE = re.compile(r"https?://[^\s]+", re.IGNORECASE)
HANDLE_RE = re.compile(r"@[a-z0-9_]{3,}", re.IGNORECASE)
HEX_RE = re.compile(r"0x[a-f0-9]{8,}", re.IGNORECASE)
DOMAIN_RE = re.compile(r"\b[a-z0-9-]+\.(?:com|io|co|ai|org|net|app|dev|xyz|gg|money|site)\b", re.IGNORECASE)


def normalize_snippet(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def strip_url_noise(text: str) -> str:
    return text.rstrip(".,!?)]}'\"")


def extract_artifacts(text: str) -> list[str]:
    found: list[str] = []
    for match in URL_RE.findall(text):
        found.append(strip_url_noise(match))
    for match in HANDLE_RE.findall(text):
        if match not in found:
            found.append(match)
    for match in HEX_RE.findall(text):
        if match not in found:
            found.append(match)
    for match in DOMAIN_RE.findall(text):
        lowered = match.lower()
        if lowered not in {item.lower() for item in found}:
            found.append(match)
    return found


def family_hint(artifact: str) -> str:
    lowered = artifact.lower()
    if lowered.startswith("http"):
        if "meet.google.com" in lowered:
            return "meeting_link"
        if "github.com" in lowered:
            return "github_link"
        if "gist.github.com" in lowered:
            return "gist_link"
        if "x.com/" in lowered or "twitter.com/" in lowered:
            return "x_link"
        if "notion.site" in lowered:
            return "notion_link"
        if "docs." in lowered:
            return "docs_link"
        if "app." in lowered:
            return "app_link"
        return "url"
    if lowered.startswith("@"):
        return "handle"
    if lowered.startswith("0x"):
        return "wallet_or_address"
    if "." in lowered:
        return "domain"
    return "artifact"


def load_rows(db: Path, bucket: str, limit: int) -> list[dict[str, Any]]:
    with sqlite3.connect(db) as conn:
        conn.row_factory = sqlite3.Row
        rows = conn.execute(QUERIES[bucket], (limit,)).fetchall()
    return [dict(row) for row in rows]


def mine_candidates(db: Path, limit: int) -> dict[str, Any]:
    by_bucket: dict[str, list[dict[str, Any]]] = {}
    for bucket in QUERIES:
        rows = load_rows(db, bucket, limit)
        candidates: list[dict[str, Any]] = []
        seen: set[tuple[int, int]] = set()
        for row in rows:
            text = row["text_content"] or ""
            artifacts = extract_artifacts(text)
            if not artifacts:
                continue
            key = (int(row["chat_id"]), int(row["id"]))
            if key in seen:
                continue
            seen.add(key)
            candidates.append(
                {
                    "chat_id": int(row["chat_id"]),
                    "message_id": int(row["id"]),
                    "date": float(row["date"]),
                    "bucket": bucket,
                    "artifacts": artifacts,
                    "artifactHints": [family_hint(item) for item in artifacts],
                    "snippet": normalize_snippet(text)[:260],
                }
            )
        by_bucket[bucket] = candidates

    flattened = sorted(
        [item for bucket_items in by_bucket.values() for item in bucket_items],
        key=lambda row: row["date"],
        reverse=True,
    )
    return {
        "db": str(db),
        "candidateCount": len(flattened),
        "byBucket": by_bucket,
        "candidates": flattened,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Mine grounded exact-lookup candidate messages from local SQLite.")
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--limit", type=int, default=DEFAULT_LIMIT)
    args = parser.parse_args()
    print(json.dumps(mine_candidates(args.db, args.limit), indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
