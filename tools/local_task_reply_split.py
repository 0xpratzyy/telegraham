#!/usr/bin/env python3
"""Classify local Pidgy DB candidates into reply queue vs effort tasks.

This is a probe script. It reads local SQLite data, sends compact candidate
evidence to the AI classifier, and prints two buckets without changing product
state.
"""

import argparse
import json
import os
import socket
import sqlite3
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Optional


APP_SUPPORT = Path.home() / "Library" / "Application Support" / "Pidgy"
DEFAULT_DB_PATH = APP_SUPPORT / "pidgy.db"
OPENAI_KEY_PATH = APP_SUPPORT / "credentials" / "com.pidgy.aiApiKey.openai"
DEFAULT_OUT_PATH = APP_SUPPORT / "debug" / "local_task_reply_split.json"


SYSTEM_PROMPT = """
You are a routing classifier for a Telegram deep-work dashboard.

For each local Pidgy candidate, decide whether it belongs in:
- "reply_only": the user owes a chat reply, confirmation, answer, or quick clarification.
- "effort_task": the user is being asked to do non-trivial work outside the chat.
- "ignore": the ask is not directed to the user, is ambient chatter, is already closed, is a bot/channel-style item, or ownership is too unclear.

Important judgment rules:
- A result can be reply_only or effort_task only when the ask is directed to the user or strongly implied to be for the user.
- Do not rely only on @mentions or name tags. In small groups, infer implied ownership from the conversation: prior [ME] commitments, direct follow-up to the user's last message, clear role/project ownership in the messages, or the other person asking the user a question.
- Do not mark an item as yours merely because the group is small.
- In groups, an inbound message like "I need X", "we need X", "can someone X", or "X would work" is not directed to the user by itself.
- In groups, an inbound message like "pls connect", "please send", or "can someone help" with no named recipient is unclear, not implied_to_me, unless it follows a [ME] offer/commitment or answers a [ME] question.
- If [ME] is telling another person to do something, the next step is on that person. Use ignore unless later evidence shows [ME] took the task back.
- If the ask targets someone else, use ignore unless [ME] later accepts that work.
- If ownership is genuinely unclear, use ignore.
- reply_only means a message back is enough and the work is roughly under five minutes.
- effort_task means the user needs to prepare, review, fix, send an artifact, introduce people, schedule, pay, investigate, update a doc/config, or otherwise do work beyond a quick reply.
- A request to send or share a pitch deck, deck, doc, file, link, invoice, contract, screenshot, media, or another artifact is effort_task when Pratyush owns it, even if he can also reply with a short note.
- If both a reply and outside work are needed, choose effort_task.
- Treat FYIs, status dumps, greetings, generic broadcasts, and closed loops as ignore.
- Use only the chat metadata and raw messages as evidence. Older extractor labels are not provided to you because they may be wrong.
- Latest state wins. Do not classify an older question as reply_only if a later [ME] message already answers, supersedes, or redirects it.
- If a later message from the other person accepts ownership ("sure", "ok", "will do", "will send", "on it") and there is no newer ask to Pratyush after that, route must be ignore with that person as ownerOfNextStep.
- If directedness is "not_me" or "unclear", route must be "ignore".
- Payment, salary, billing, transfer, funds, or invoice actions are effort_task even if the final step is a short confirmation.
- Testing or trying a product/app and sharing feedback is effort_task unless it only asks for a quick opinion from existing knowledge.
- Checking rules, paperwork, import requirements, legal requirements, or docs is effort_task.
- Reviewing a deck, doc, profile, contract, design, or pitch is effort_task when actual review is needed.
- Always fill ownerOfNextStep with the person/chat who owns the next move. Use "Pratyush" only when the user truly owns it.
- route and ownerOfNextStep must agree:
  - If ownerOfNextStep is "Pratyush", choose reply_only or effort_task depending on effort.
  - If ownerOfNextStep is anyone other than "Pratyush", route must be ignore.
  - Never return reply_only or effort_task with ownerOfNextStep set to another person.
- For ignore, explain why this is not on Pratyush in whyNotUser.

Return JSON only:
{
  "results": [
    {
      "caseId": "task:123",
      "route": "effort_task",
      "directedness": "implied_to_me",
      "effortLevel": "non_trivial_work",
      "title": "Review contract redlines",
      "personName": "Akhil",
      "chatTitle": "Akhil",
      "suggestedAction": "Review the diff and reply with comments.",
      "reason": "The contact asks the user to review contract changes.",
      "ownerOfNextStep": "Pratyush",
      "whyNotUser": "",
      "confidence": 0.88,
      "supportingMessageIds": [501]
    }
  ]
}

Valid route values: "reply_only", "effort_task", "ignore"
Valid directedness values: "direct_to_me", "implied_to_me", "not_me", "unclear"
Valid effortLevel values: "none", "quick_reply", "non_trivial_work"

Anti-examples:
- [ME]: "Rajanshee put base regional communities as well" means Pratyush is assigning Rajanshee. ownerOfNextStep is Rajanshee, route is ignore.
- In a group, Sarv: "I need this as a UGC example" and "Even a selfie with the gotchi would work" is not on Pratyush unless the messages show Pratyush was asked directly or had already offered/committed.
- In a group, Sarv: "Also pls connect with emergent team as well" with no recipient is unclear/ignore unless the prior messages show Sarv is addressing Pratyush.
- [ME]: "Can you send in evening" followed by Mayur: "Ok, will have it sent tomorrow" means ownerOfNextStep is Mayur, route is ignore.
- In a DM, "Bro, can you please send me the pitch deck for dacoit" means ownerOfNextStep is Pratyush and route is effort_task, not reply_only, because he must provide an artifact.
""".strip()


@dataclass
class Candidate:
    case_id: str
    source: str
    source_id: str
    chat_id: int
    chat_title: str
    chat_type: str
    title_hint: str
    person_hint: str
    topic_hint: str
    priority_hint: str
    suggested_action_hint: str
    summary_hint: str
    latest_at: float
    messages: list[dict[str, Any]]


def load_api_key(use_saved_key: bool) -> Optional[str]:
    env_key = os.environ.get("OPENAI_API_KEY", "").strip()
    if env_key:
        return env_key
    if use_saved_key and OPENAI_KEY_PATH.exists():
        return OPENAI_KEY_PATH.read_text(encoding="utf-8").strip()
    return None


def connect(path: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    return conn


def is_bot_like(row: sqlite3.Row) -> bool:
    entity_type = (row["entity_type"] or "").lower()
    if entity_type == "channel":
        return True
    raw_metadata = row["metadata"] if "metadata" in row.keys() else None
    if not raw_metadata:
        return False
    try:
        metadata = json.loads(raw_metadata)
    except (TypeError, json.JSONDecodeError):
        return False
    return metadata.get("isBot") is True


def fetch_messages_for_chat(conn: sqlite3.Connection, chat_id: int, limit: int) -> list[dict[str, Any]]:
    rows = conn.execute(
        """
        SELECT id, sender_name, date, text_content, is_outgoing
        FROM messages
        WHERE chat_id = ? AND text_content IS NOT NULL AND length(trim(text_content)) > 0
        ORDER BY date DESC, id DESC
        LIMIT ?
        """,
        (chat_id, limit),
    ).fetchall()
    return [
        {
            "messageId": int(row["id"]),
            "sender": "[ME]" if row["is_outgoing"] else (row["sender_name"] or "Unknown"),
            "date": float(row["date"] or 0),
            "text": row["text_content"] or "",
        }
        for row in reversed(rows)
    ]


def fetch_task_messages(conn: sqlite3.Connection, task_id: int, chat_id: int, fallback_limit: int) -> list[dict[str, Any]]:
    rows = conn.execute(
        """
        SELECT message_id, sender_name, date, text
        FROM dashboard_task_sources
        WHERE task_id = ?
        ORDER BY date ASC, message_id ASC
        LIMIT 8
        """,
        (task_id,),
    ).fetchall()
    if rows:
        source_messages = [
            {
                "messageId": int(row["message_id"]),
                "sender": "[ME]" if (row["sender_name"] or "").strip().lower() in {"me", "[me]"} else (row["sender_name"] or "Unknown"),
                "date": float(row["date"] or 0),
                "text": row["text"] or "",
            }
            for row in rows
        ]
        context = fetch_task_context_messages(conn, chat_id, source_messages, fallback_limit)
        if context:
            return context
        return source_messages
    return fetch_messages_for_chat(conn, chat_id, fallback_limit)


def fetch_task_context_messages(
    conn: sqlite3.Connection,
    chat_id: int,
    source_messages: list[dict[str, Any]],
    limit: int,
) -> list[dict[str, Any]]:
    source_ids = [int(message["messageId"]) for message in source_messages]
    if not source_ids:
        return []

    placeholders = ",".join("?" for _ in source_ids)
    source_rows = conn.execute(
        f"""
        SELECT id, date
        FROM messages
        WHERE chat_id = ? AND id IN ({placeholders})
        """,
        (chat_id, *source_ids),
    ).fetchall()
    if source_rows:
        dates = [float(row["date"] or 0) for row in source_rows]
    else:
        dates = [float(message.get("date") or 0) for message in source_messages if float(message.get("date") or 0) > 0]
    if not dates:
        return []

    start = min(dates) - 6 * 3600
    end = max(dates) + 36 * 3600
    message_rows = conn.execute(
        """
        SELECT id, sender_name, date, text_content, is_outgoing
        FROM messages
        WHERE chat_id = ?
          AND text_content IS NOT NULL
          AND length(trim(text_content)) > 0
          AND date BETWEEN ? AND ?
        ORDER BY date ASC, id ASC
        LIMIT ?
        """,
        (chat_id, start, end, max(limit, 20)),
    ).fetchall()
    context = [
        {
            "messageId": int(row["id"]),
            "sender": "[ME]" if row["is_outgoing"] else (row["sender_name"] or "Unknown"),
            "date": float(row["date"] or 0),
            "text": row["text_content"] or "",
        }
        for row in message_rows
    ]

    task_source_rows = conn.execute(
        """
        SELECT dts.message_id, dts.sender_name, dts.date, dts.text
        FROM dashboard_task_sources dts
        JOIN dashboard_tasks dt ON dt.id = dts.task_id
        WHERE dt.chat_id = ?
          AND dts.date BETWEEN ? AND ?
        ORDER BY dts.date ASC, dts.message_id ASC
        LIMIT ?
        """,
        (chat_id, start, end, max(limit, 20)),
    ).fetchall()
    context.extend(
        {
            "messageId": int(row["message_id"]),
            "sender": "[ME]" if (row["sender_name"] or "").strip().lower() in {"me", "[me]"} else (row["sender_name"] or "Unknown"),
            "date": float(row["date"] or 0),
            "text": row["text"] or "",
        }
        for row in task_source_rows
    )

    by_id: dict[int, dict[str, Any]] = {}
    for message in [*source_messages, *context]:
        message_id = int(message["messageId"])
        existing = by_id.get(message_id)
        if existing is None or (existing.get("sender") == "Unknown" and message.get("sender") != "Unknown"):
            by_id[message_id] = message
    return sorted(by_id.values(), key=lambda item: (float(item.get("date") or 0), int(item["messageId"])))


def load_task_candidates(conn: sqlite3.Connection, days: int, limit: int, message_limit: int) -> list[Candidate]:
    cutoff = time.time() - days * 86400
    rows = conn.execute(
        """
        SELECT
            dt.id,
            dt.title,
            dt.summary,
            dt.suggested_action,
            dt.person_name,
            dt.chat_id,
            dt.chat_title,
            dt.topic_name,
            dt.priority,
            COALESCE(dt.latest_source_date, dt.updated_at, dt.created_at) AS latest_at,
            n.entity_type,
            n.display_name,
            n.username,
            n.metadata
        FROM dashboard_tasks dt
        LEFT JOIN nodes n ON n.entity_id = dt.chat_id
        WHERE dt.status = 'open'
          AND COALESCE(dt.latest_source_date, dt.updated_at, dt.created_at) >= ?
        ORDER BY COALESCE(dt.latest_source_date, dt.updated_at, dt.created_at) DESC, dt.id DESC
        LIMIT ?
        """,
        (cutoff, limit),
    ).fetchall()

    candidates: list[Candidate] = []
    for row in rows:
        if is_bot_like(row):
            continue
        chat_id = int(row["chat_id"])
        task_id = int(row["id"])
        messages = fetch_task_messages(conn, task_id, chat_id, message_limit)
        candidates.append(
            Candidate(
                case_id=f"task:{task_id}",
                source="dashboard_task",
                source_id=str(task_id),
                chat_id=chat_id,
                chat_title=row["chat_title"] or row["display_name"] or str(chat_id),
                chat_type=row["entity_type"] or "unknown",
                title_hint=row["title"] or "",
                person_hint=row["person_name"] or "",
                topic_hint=row["topic_name"] or "",
                priority_hint=row["priority"] or "",
                suggested_action_hint=row["suggested_action"] or "",
                summary_hint=row["summary"] or "",
                latest_at=float(row["latest_at"] or 0),
                messages=messages,
            )
        )
    return candidates


def load_reply_candidates(conn: sqlite3.Connection, limit: int, message_limit: int) -> list[Candidate]:
    rows = conn.execute(
        """
        SELECT
            pc.chat_id,
            pc.category,
            pc.suggested_action,
            pc.analyzed_at,
            n.entity_type,
            n.display_name,
            n.username,
            n.metadata
        FROM pipeline_cache pc
        LEFT JOIN nodes n ON n.entity_id = pc.chat_id
        WHERE pc.category = 'on_me'
        ORDER BY pc.analyzed_at DESC
        LIMIT ?
        """,
        (limit,),
    ).fetchall()

    candidates: list[Candidate] = []
    for row in rows:
        if is_bot_like(row):
            continue
        chat_id = int(row["chat_id"])
        candidates.append(
            Candidate(
                case_id=f"reply:{chat_id}",
                source="reply_cache",
                source_id=str(chat_id),
                chat_id=chat_id,
                chat_title=row["display_name"] or str(chat_id),
                chat_type=row["entity_type"] or "unknown",
                title_hint="",
                person_hint=row["display_name"] or "",
                topic_hint="",
                priority_hint="",
                suggested_action_hint=row["suggested_action"] or "",
                summary_hint="",
                latest_at=float(row["analyzed_at"] or 0),
                messages=fetch_messages_for_chat(conn, chat_id, message_limit),
            )
        )
    return candidates


def dedupe_candidates(candidates: Iterable[Candidate]) -> list[Candidate]:
    seen: set[str] = set()
    output: list[Candidate] = []
    for candidate in candidates:
        key = candidate.case_id
        if key in seen:
            continue
        seen.add(key)
        output.append(candidate)
    return output


def group_candidates_by_chat(candidates: list[Candidate]) -> list[Candidate]:
    grouped: dict[int, Candidate] = {}
    messages_by_chat: dict[int, dict[int, dict[str, Any]]] = {}

    for candidate in candidates:
        existing = grouped.get(candidate.chat_id)
        if existing is None:
            grouped[candidate.chat_id] = Candidate(
                case_id=f"chat:{candidate.chat_id}",
                source="combined",
                source_id=candidate.source_id,
                chat_id=candidate.chat_id,
                chat_title=candidate.chat_title,
                chat_type=candidate.chat_type,
                title_hint=candidate.title_hint,
                person_hint=candidate.person_hint,
                topic_hint=candidate.topic_hint,
                priority_hint=candidate.priority_hint,
                suggested_action_hint=candidate.suggested_action_hint,
                summary_hint=candidate.summary_hint,
                latest_at=candidate.latest_at,
                messages=[],
            )
            messages_by_chat[candidate.chat_id] = {}
        else:
            existing.source_id = join_unique(existing.source_id, candidate.source_id)
            existing.title_hint = join_unique(existing.title_hint, candidate.title_hint)
            existing.person_hint = join_unique(existing.person_hint, candidate.person_hint)
            existing.topic_hint = join_unique(existing.topic_hint, candidate.topic_hint)
            existing.priority_hint = join_unique(existing.priority_hint, candidate.priority_hint)
            existing.suggested_action_hint = join_unique(existing.suggested_action_hint, candidate.suggested_action_hint)
            existing.summary_hint = join_unique(existing.summary_hint, candidate.summary_hint, max_parts=3)
            existing.latest_at = max(existing.latest_at, candidate.latest_at)

        for message in candidate.messages:
            messages_by_chat[candidate.chat_id][int(message["messageId"])] = message

    for chat_id, candidate in grouped.items():
        candidate.messages = sorted(
            messages_by_chat[chat_id].values(),
            key=lambda item: (float(item.get("date") or 0), int(item["messageId"])),
        )
    return sorted(grouped.values(), key=lambda item: item.latest_at, reverse=True)


def join_unique(existing: str, incoming: str, max_parts: int = 8) -> str:
    values: list[str] = []
    for chunk in [existing, incoming]:
        for part in str(chunk or "").split(" | "):
            clean = part.strip()
            if clean and clean not in values:
                values.append(clean)
    return " | ".join(values[:max_parts])


def chunked(items: list[Candidate], size: int) -> Iterable[list[Candidate]]:
    for index in range(0, len(items), size):
        yield items[index : index + size]


def format_date(ts: float) -> str:
    if not ts:
        return "unknown"
    return time.strftime("%Y-%m-%d %H:%M", time.localtime(ts))


def build_user_message(candidates: list[Candidate]) -> str:
    lines = [
        "Classify these real local Pidgy candidates.",
        "The current user is Pratyush, also known as @pratyush. [ME] means Pratyush sent that message.",
        "Use only the chat metadata and raw messages as evidence.",
        "",
        "Candidates:",
    ]
    for candidate in candidates:
        lines.append("")
        lines.append("---")
        lines.append(f"caseId: {candidate.case_id}")
        lines.append(f"chatId: {candidate.chat_id}")
        lines.append(f"chatTitle: {candidate.chat_title}")
        lines.append(f"chatType: {candidate.chat_type}")
        lines.append(f"latestAt: {format_date(candidate.latest_at)}")
        lines.append("messages:")
        for message in candidate.messages[-20:]:
            text = " ".join(str(message["text"]).split())
            if len(text) > 420:
                text = text[:417] + "..."
            lines.append(
                f"[messageId: {message['messageId']}] "
                f"[{format_date(float(message.get('date') or 0))}] "
                f"{message['sender']}: {text}"
            )
    return "\n".join(lines)


def call_openai(model: str, api_key: str, candidates: list[Candidate], retries: int = 3) -> dict[str, Any]:
    body = {
        "model": model,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": build_user_message(candidates)},
        ],
        "temperature": 0,
        "response_format": response_format_for_candidates(candidates),
    }
    req = urllib.request.Request(
        "https://api.openai.com/v1/chat/completions",
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    for attempt in range(1, retries + 1):
        try:
            with urllib.request.urlopen(req, timeout=120) as response:
                payload = json.loads(response.read().decode("utf-8"))
            break
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            if exc.code not in {408, 409, 429, 500, 502, 503, 504} or attempt == retries:
                raise RuntimeError(f"OpenAI HTTP {exc.code}: {detail}") from exc
            wait = 2 * attempt
            print(f"retrying batch after HTTP {exc.code} in {wait}s...", file=sys.stderr)
            time.sleep(wait)
        except (urllib.error.URLError, TimeoutError, ConnectionResetError, socket.timeout) as exc:
            if attempt == retries:
                raise
            wait = 2 * attempt
            print(f"retrying batch after network error in {wait}s: {exc}", file=sys.stderr)
            time.sleep(wait)
    else:
        raise RuntimeError("OpenAI request failed without a response")

    content = payload["choices"][0]["message"]["content"]
    parsed = json.loads(content)
    parsed["_usage"] = payload.get("usage", {})
    parsed["_model"] = payload.get("model", model)
    return parsed


def response_format_for_candidates(candidates: list[Candidate]) -> dict[str, Any]:
    return {
        "type": "json_schema",
        "json_schema": {
            "name": "local_task_reply_split",
            "strict": True,
            "schema": {
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "results": {
                        "type": "array",
                        "minItems": len(candidates),
                        "maxItems": len(candidates),
                        "items": {
                            "type": "object",
                            "additionalProperties": False,
                            "properties": {
                                "caseId": {"type": "string", "enum": [candidate.case_id for candidate in candidates]},
                                "route": {"type": "string", "enum": ["reply_only", "effort_task", "ignore"]},
                                "directedness": {"type": "string", "enum": ["direct_to_me", "implied_to_me", "not_me", "unclear"]},
                                "effortLevel": {"type": "string", "enum": ["none", "quick_reply", "non_trivial_work"]},
                                "title": {"type": "string"},
                                "personName": {"type": "string"},
                                "chatTitle": {"type": "string"},
                                "suggestedAction": {"type": "string"},
                                "reason": {"type": "string"},
                                "ownerOfNextStep": {"type": "string"},
                                "whyNotUser": {"type": "string"},
                                "confidence": {"type": "number"},
                                "supportingMessageIds": {
                                    "type": "array",
                                    "items": {"type": "integer"},
                                },
                            },
                            "required": [
                                "caseId",
                                "route",
                                "directedness",
                                "effortLevel",
                                "title",
                                "personName",
                                "chatTitle",
                                "suggestedAction",
                                "reason",
                                "ownerOfNextStep",
                                "whyNotUser",
                                "confidence",
                                "supportingMessageIds",
                            ],
                        },
                    }
                },
                "required": ["results"],
            },
        },
    }


def merge_results(candidates: list[Candidate], payloads: list[dict[str, Any]]) -> list[dict[str, Any]]:
    by_id = {candidate.case_id: candidate for candidate in candidates}
    rows: list[dict[str, Any]] = []
    for payload in payloads:
        for item in payload.get("results", []):
            case_id = str(item.get("caseId", ""))
            candidate = by_id.get(case_id)
            if not candidate:
                continue
            rows.append(
                {
                    **item,
                    "source": candidate.source,
                    "sourceId": candidate.source_id,
                    "chatId": candidate.chat_id,
                    "chatTitle": item.get("chatTitle") or candidate.chat_title,
                    "personName": item.get("personName") or candidate.person_hint,
                    "latestAt": candidate.latest_at,
                }
            )
    return rows


def dedupe_rows(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    route_rank = {"effort_task": 2, "reply_only": 1, "ignore": 0}
    best: dict[tuple[str, str, str], dict[str, Any]] = {}
    for row in rows:
        route = str(row.get("route", "ignore"))
        chat_id = str(row.get("chatId", ""))
        title = str(row.get("title") or "").strip().lower()
        if route == "reply_only":
            key = (route, chat_id, "reply")
        else:
            key = (route, chat_id, title)
        current = best.get(key)
        if current is None:
            best[key] = row
            continue
        current_score = float(current.get("confidence") or 0) + route_rank.get(str(current.get("route")), 0)
        row_score = float(row.get("confidence") or 0) + route_rank.get(route, 0)
        if row_score > current_score:
            best[key] = row
    return list(best.values())


def strip_internal_fields(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    cleaned: list[dict[str, Any]] = []
    for row in rows:
        cleaned.append({key: value for key, value in row.items() if not key.startswith("_")})
    return cleaned


def row_label(row: dict[str, Any]) -> str:
    person = str(row.get("personName") or "").strip()
    chat = str(row.get("chatTitle") or "").strip()
    title = str(row.get("title") or "").strip()
    action = str(row.get("suggestedAction") or "").strip()
    confidence = row.get("confidence")
    conf_text = f"{float(confidence):.2f}" if isinstance(confidence, (int, float)) else "?"
    owner = str(row.get("directedness") or "?")
    head = person if person and person.lower() not in {"unknown", "uncategorized", "me"} else chat
    if not head:
        head = chat or "Unknown"
    body = title or action or str(row.get("reason") or "")
    if action and action != body:
        body = f"{body} -> {action}"
    return f"- {head} ({chat}) [{owner}, {conf_text}]: {body}"


def print_bucket(title: str, rows: list[dict[str, Any]], max_rows: int) -> None:
    rows = sorted(rows, key=lambda r: (float(r.get("latestAt") or 0), float(r.get("confidence") or 0)), reverse=True)
    print(f"\n## {title} ({len(rows)})")
    for row in rows[:max_rows]:
        print(row_label(row))
    if len(rows) > max_rows:
        print(f"- ... {len(rows) - max_rows} more in JSON output")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=DEFAULT_DB_PATH)
    parser.add_argument("--model", default="gpt-4.1-mini")
    parser.add_argument("--use-saved-key", action="store_true")
    parser.add_argument("--days", type=int, default=14)
    parser.add_argument("--max-task-candidates", type=int, default=180)
    parser.add_argument("--max-reply-candidates", type=int, default=80)
    parser.add_argument("--message-limit", type=int, default=10)
    parser.add_argument("--batch-size", type=int, default=18)
    parser.add_argument("--max-print", type=int, default=80)
    parser.add_argument("--no-group-by-chat", action="store_true", help="Classify raw task/reply rows instead of one combined candidate per chat.")
    parser.add_argument("--only-chat-title", default="", help="Debug filter for candidates with this exact chat title.")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT_PATH)
    args = parser.parse_args()

    api_key = load_api_key(args.use_saved_key)
    if not api_key:
        print("No API key. Set OPENAI_API_KEY or pass --use-saved-key.", file=sys.stderr)
        return 2

    conn = connect(args.db)
    try:
        candidates = dedupe_candidates(
            [
                *load_reply_candidates(conn, args.max_reply_candidates, args.message_limit),
                *load_task_candidates(conn, args.days, args.max_task_candidates, args.message_limit),
            ]
        )
    finally:
        conn.close()

    if not candidates:
        print("No local candidates found.")
        return 0
    if args.only_chat_title:
        candidates = [candidate for candidate in candidates if candidate.chat_title == args.only_chat_title]
        if not candidates:
            print(f"No candidates found for chat title {args.only_chat_title!r}.")
            return 0
    if not args.no_group_by_chat:
        candidates = group_candidates_by_chat(candidates)

    payloads: list[dict[str, Any]] = []
    total_prompt = 0
    total_completion = 0
    for index, batch in enumerate(chunked(candidates, args.batch_size), start=1):
        print(f"classifying batch {index} ({len(batch)} candidates)...", file=sys.stderr)
        payload = call_openai(args.model, api_key, batch)
        payloads.append(payload)
        usage = payload.get("_usage", {})
        total_prompt += int(usage.get("prompt_tokens") or 0)
        total_completion += int(usage.get("completion_tokens") or 0)

    merged_rows = merge_results(candidates, payloads)
    rows = merged_rows if args.no_group_by_chat else dedupe_rows(merged_rows)
    reply_rows = strip_internal_fields([row for row in rows if row.get("route") == "reply_only"])
    task_rows = strip_internal_fields([row for row in rows if row.get("route") == "effort_task"])
    ignore_rows = strip_internal_fields([row for row in rows if row.get("route") == "ignore"])

    output = {
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "model": payloads[-1].get("_model", args.model) if payloads else args.model,
        "candidateCount": len(candidates),
        "replyQueue": reply_rows,
        "tasks": task_rows,
        "ignored": ignore_rows,
        "usage": {
            "promptTokens": total_prompt,
            "completionTokens": total_completion,
            "totalTokens": total_prompt + total_completion,
        },
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(output, indent=2, sort_keys=True), encoding="utf-8")

    print(f"model: {output['model']}")
    print(f"candidates: {len(candidates)}")
    print(
        "tokens: "
        f"prompt={total_prompt} completion={total_completion} total={total_prompt + total_completion}"
    )
    print(f"json: {args.out}")
    print_bucket("Reply Queue", reply_rows, args.max_print)
    print_bucket("Tasks", task_rows, args.max_print)
    print_bucket("Ignored", ignore_rows, min(args.max_print, 25))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
