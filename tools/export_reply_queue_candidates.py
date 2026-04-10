#!/usr/bin/env python3
import argparse
import json
import math
import sqlite3
import time
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


APP_SUPPORT = Path.home() / "Library" / "Application Support" / "Pidgy"
DEFAULT_DEBUG_PATH = APP_SUPPORT / "debug" / "last_reply_queue_timing.json"
DEFAULT_DB_PATH = APP_SUPPORT / "pidgy.db"
DEFAULT_OUT_DIR = APP_SUPPORT / "debug" / "reply_queue_candidate_snapshots"


@dataclass
class Strategy:
    name: str
    limit: int


def relative_timestamp(epoch_seconds: float) -> str:
    delta = max(0, int(time.time() - epoch_seconds))
    if delta < 60:
        return f"{delta}s ago"
    if delta < 3600:
        return f"{delta // 60}m ago"
    if delta < 86400:
        return f"{delta // 3600}h ago"
    if delta < 7 * 86400:
        return f"{delta // 86400}d ago"
    return datetime.fromtimestamp(epoch_seconds, tz=timezone.utc).strftime("%b %-d")


def sanitize_text(value: Any) -> str:
    text = (value or "").strip()
    return " ".join(text.split())


def load_debug(debug_path: Path) -> dict[str, Any]:
    with debug_path.open() as handle:
        return json.load(handle)


def load_latest_messages(conn: sqlite3.Connection, chat_id: int, limit: int) -> list[dict[str, Any]]:
    rows = conn.execute(
        """
        SELECT id, date, sender_name, is_outgoing, text_content
        FROM messages
        WHERE chat_id = ?
        ORDER BY date DESC, id DESC
        LIMIT ?
        """,
        (chat_id, limit),
    ).fetchall()
    rows.reverse()
    messages = []
    for row in rows:
        sender = "[ME]" if int(row[3] or 0) else sanitize_text(row[2]) or "Unknown"
        messages.append(
            {
                "messageId": int(row[0]),
                "relativeTimestamp": relative_timestamp(float(row[1])),
                "senderFirstName": sender,
                "text": sanitize_text(row[4]) or "[non-text message]",
            }
        )
    return messages


def load_latest_timestamp(conn: sqlite3.Connection, chat_id: int) -> float:
    row = conn.execute(
        "SELECT date FROM messages WHERE chat_id = ? ORDER BY date DESC, id DESC LIMIT 1",
        (chat_id,),
    ).fetchone()
    return float(row[0]) if row else 0.0


def local_signal(audit: dict[str, Any]) -> str:
    if audit.get("effectiveGroupReplySignal"):
        return "directed_group_reply"
    if audit.get("replyOwed") or audit.get("pipelineCategory") == "on_me":
        return "on_me"
    if audit.get("pipelineCategory") == "on_them":
        return "on_them"
    return "quiet"


def build_candidates(debug_payload: dict[str, Any], conn: sqlite3.Connection) -> list[dict[str, Any]]:
    candidates = []
    for index, audit in enumerate(debug_payload.get("chatAudits", [])):
        chat_id = int(audit["chatId"])
        chat_type = audit.get("chatType", "private")
        message_limit = 6 if chat_type == "private" else 4
        candidates.append(
            {
                "order": index,
                "chatId": chat_id,
                "chatName": audit.get("chatTitle", f"Chat {chat_id}"),
                "chatType": chat_type,
                "unreadCount": 0,
                "memberCount": None,
                "localSignal": local_signal(audit),
                "pipelineHint": audit.get("pipelineCategory", "uncategorized"),
                "replyOwed": bool(audit.get("replyOwed")),
                "strictReplySignal": bool(audit.get("strictReplySignal")),
                "effectiveGroupReplySignal": bool(audit.get("effectiveGroupReplySignal")),
                "sentToAI": bool(audit.get("sentToAI")),
                "finalIncluded": bool(audit.get("finalIncluded")),
                "latestMessageDate": load_latest_timestamp(conn, chat_id),
                "messages": load_latest_messages(conn, chat_id, message_limit),
            }
        )
    return candidates


def interleave_mixed(candidates: list[dict[str, Any]], dm_ratio: int = 2) -> list[dict[str, Any]]:
    dms = [item for item in candidates if item["chatType"] == "private"]
    groups = [item for item in candidates if item["chatType"] != "private"]
    mixed = []
    while dms or groups:
        for _ in range(dm_ratio):
            if dms:
                mixed.append(dms.pop(0))
        if groups:
            mixed.append(groups.pop(0))
        if not dms and groups:
            mixed.extend(groups)
            break
        if not groups and dms:
            mixed.extend(dms)
            break
    return mixed


def strategy_order(name: str, candidates: list[dict[str, Any]]) -> list[dict[str, Any]]:
    if name == "audit_order":
        return list(candidates)
    if name == "recent_first":
        return sorted(candidates, key=lambda item: (item["latestMessageDate"], -item["order"]), reverse=True)
    if name == "mixed_recent":
        recent = sorted(candidates, key=lambda item: (item["latestMessageDate"], -item["order"]), reverse=True)
        return interleave_mixed(recent)
    if name == "ai_only_recent":
        filtered = [item for item in candidates if item["sentToAI"]]
        return sorted(filtered, key=lambda item: (item["latestMessageDate"], -item["order"]), reverse=True)
    raise ValueError(f"Unknown strategy: {name}")


def write_snapshot(
    out_path: Path,
    debug_payload: dict[str, Any],
    candidates: list[dict[str, Any]],
    strategy_name: str,
) -> None:
    payload = {
        "query": debug_payload.get("query"),
        "scope": (debug_payload.get("querySpec") or {}).get("scope", "all"),
        "providerName": (debug_payload.get("debug") or {}).get("providerName", "OpenAI"),
        "providerModel": (debug_payload.get("debug") or {}).get("providerModel", "gpt-5-mini"),
        "capturedAt": datetime.now(timezone.utc).isoformat(),
        "strategy": strategy_name,
        "candidates": candidates,
    }
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(payload, indent=2, sort_keys=True))


def default_strategy_specs() -> list[Strategy]:
    return [
        Strategy(name="audit_order", limit=24),
        Strategy(name="recent_first", limit=24),
        Strategy(name="mixed_recent", limit=24),
        Strategy(name="mixed_recent", limit=48),
        Strategy(name="ai_only_recent", limit=24),
    ]


def main() -> int:
    parser = argparse.ArgumentParser(description="Export reply queue candidate snapshots from saved debug + SQLite.")
    parser.add_argument("--debug", type=Path, default=DEFAULT_DEBUG_PATH)
    parser.add_argument("--db", type=Path, default=DEFAULT_DB_PATH)
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    parser.add_argument(
        "--strategy",
        action="append",
        help="Custom strategy in form name:limit (supported names: audit_order,recent_first,mixed_recent,ai_only_recent)",
    )
    args = parser.parse_args()

    if not args.debug.exists():
        raise SystemExit(f"Debug file not found: {args.debug}")
    if not args.db.exists():
        raise SystemExit(f"DB file not found: {args.db}")

    debug_payload = load_debug(args.debug)
    conn = sqlite3.connect(args.db)
    try:
        base_candidates = build_candidates(debug_payload, conn)
    finally:
        conn.close()

    specs = []
    if args.strategy:
        for raw in args.strategy:
            name, limit = raw.split(":", 1)
            specs.append(Strategy(name=name, limit=int(limit)))
    else:
        specs = default_strategy_specs()

    for spec in specs:
        ordered = strategy_order(spec.name, base_candidates)[: spec.limit]
        out_path = args.out_dir / f"{spec.name}_{spec.limit}.json"
        write_snapshot(out_path, debug_payload, ordered, f"{spec.name}:{spec.limit}")
        print(f"wrote {out_path} ({len(ordered)} candidates)")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
