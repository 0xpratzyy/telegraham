#!/usr/bin/env python3
import argparse
import json
import re
import sqlite3
import time
from collections import defaultdict
from pathlib import Path
from typing import Any, Optional


DEFAULT_DB = Path("/Users/pratyushrungta/Library/Application Support/Pidgy/pidgy.db")
DEFAULT_ORACLE = Path("/Users/pratyushrungta/telegraham/evals/summary_oracle_v3.json")

STOP_WORDS = {
    "what", "did", "we", "with", "the", "a", "an", "and", "or", "to", "of", "for",
    "me", "my", "our", "about", "give", "quick", "summary", "summarize", "summarise",
    "recap", "last", "last-week", "this-week",
    "week", "month", "from", "this", "that", "right", "now", "after", "latest",
    "recent", "context", "lately",
    "happened", "discuss", "discussed", "conclude", "concluded", "decide",
    "decided", "main", "gaps", "chat", "chats", "thread", "conversation", "are", "is", "was", "were"
}

SUMMARY_CUE_PHRASES = [
    "what did we decide", "what happened", "key takeaways", "latest context",
    "catch me up", "full rankings", "team brief", "main gaps", "feedback",
    "overview", "full picture"
]


def normalize(text: str) -> str:
    return re.sub(r"\s+", " ", text.strip().lower())


def load_oracle(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text())


def sanitize_token(token: str) -> str:
    return token.strip(".-")


def tokenize(text: str) -> list[str]:
    tokens = []
    for raw_token in re.split(r"[^a-z0-9@._-]+", normalize(text)):
        token = sanitize_token(raw_token)
        if token and token not in STOP_WORDS and len(token) >= 3:
            tokens.append(token)
    return list(dict.fromkeys(tokens))


def safe_fts_terms(text: str) -> list[str]:
    cleaned = normalize(text).replace("@", " ")
    cleaned = re.sub(r"[^a-z0-9]+", " ", cleaned)
    return [
        token
        for token in cleaned.split()
        if token and token not in STOP_WORDS and len(token) >= 3
    ]


def phraseify(hints: list[str]) -> list[str]:
    phrases: list[str] = []
    for hint in hints:
        hint = normalize(hint).replace("@", "")
        hint = re.sub(r"[^a-z0-9 ]+", " ", hint)
        hint = re.sub(r"\s+", " ", hint).strip()
        if not hint:
            continue
        phrases.append(hint)
    return list(dict.fromkeys(phrases))


def distinct_terms(values: list[str]) -> list[str]:
    terms: list[str] = []
    for value in values:
        terms.extend(safe_fts_terms(value))
    return list(dict.fromkeys(terms))


def extract_name_tokens(values: list[str]) -> list[str]:
    names: list[str] = []
    for value in values:
        for match in re.findall(r"\b[A-Z][a-zA-Z0-9_]+\b", value):
            lowered = match.lower()
            if lowered not in STOP_WORDS and len(lowered) >= 4:
                names.append(lowered)
    return list(dict.fromkeys(names))


def extract_scoped_terms(normalized: str) -> list[str]:
    patterns = [
        r"\bwith\s+([a-z0-9@.\- ]+?)(?:\s+(?:from|about|last|this|today|yesterday|thread|chat|conversation|project)\b|[?.!]|$)",
        r"\babout\s+([a-z0-9@.\- ]+?)(?:\s+(?:from|last|this|today|yesterday|thread|chat|conversation|project)\b|[?.!]|$)",
    ]
    for pattern in patterns:
        match = re.search(pattern, normalized, re.IGNORECASE)
        if not match:
            continue
        extracted = []
        for raw_token in re.split(r"[^a-z0-9@._-]+", match.group(1)):
            token = sanitize_token(raw_token)
            if token and token not in STOP_WORDS and len(token) >= 3:
                extracted.append(token)
        if extracted:
            return list(dict.fromkeys(extracted))
    return []


def build_query_context(query: str) -> dict[str, Any]:
    normalized = normalize(query)
    query_terms = tokenize(query)
    scoped_terms = extract_scoped_terms(normalized)
    clue_phrases = [phrase for phrase in SUMMARY_CUE_PHRASES if phrase in normalized]
    generic_tokens = {
        token
        for phrase in clue_phrases
        for token in re.split(r"[^a-z0-9]+", phrase)
        if token
    }
    topic_terms = [
        token for token in query_terms
        if token not in scoped_terms and token not in generic_tokens
    ]
    if len(scoped_terms) == 1 and not topic_terms:
        sender_fallback_terms = list(dict.fromkeys(scoped_terms))
    elif not scoped_terms and len(topic_terms) == 1 and len(query_terms) <= 3:
        sender_fallback_terms = list(dict.fromkeys(topic_terms))
    else:
        sender_fallback_terms = []
    retrieval_terms = scoped_terms + topic_terms if (scoped_terms or topic_terms) else query_terms
    return {
        "normalized": normalized,
        "queryTerms": query_terms,
        "scopedTerms": list(dict.fromkeys(scoped_terms)),
        "topicTerms": list(dict.fromkeys(topic_terms)),
        "senderFallbackTerms": sender_fallback_terms,
        "cluePhrases": clue_phrases,
        "prefersImplicitRecentWindow": bool(sender_fallback_terms),
        "retrievalTerms": list(dict.fromkeys(retrieval_terms)),
    }


def effective_time_range(
    time_range: Optional[dict[str, Any]],
    query_context: dict[str, Any]
) -> Optional[dict[str, Any]]:
    if time_range:
        return time_range
    if not query_context.get("prefersImplicitRecentWindow"):
        return None
    now = int(time.time())
    lookback_days = 7
    return {
        "start": now - (lookback_days * 86_400),
        "end": now
    }


def build_match_query(query: str, hints: list[str], query_context: dict[str, Any]) -> str:
    pieces: list[str] = []
    for phrase in phraseify(hints):
        cleaned = re.sub(r"[^a-z0-9 ]+", " ", phrase).strip()
        if not cleaned:
            continue
        if " " in cleaned:
            pieces.append(f"\"{cleaned}\"")
        else:
            for token in cleaned.split():
                if token not in pieces:
                    pieces.append(token)
    normalized_retrieval_terms: list[str] = []
    for token in query_context.get("retrievalTerms", []) or safe_fts_terms(query):
        normalized_retrieval_terms.extend(safe_fts_terms(token))
    for token in normalized_retrieval_terms:
        if token not in pieces:
            pieces.append(token)
    if not pieces:
        return ""
    return " OR ".join(pieces)


def fetch_fts_hits(
    conn: sqlite3.Connection,
    query: str,
    hints: list[str],
    query_context: dict[str, Any],
    time_range: Optional[dict[str, Any]],
    limit: int = 240,
) -> list[sqlite3.Row]:
    match_query = build_match_query(query, hints, query_context)
    if not match_query:
        return []
    conn.row_factory = sqlite3.Row
    sql = """
        select
            m.chat_id,
            m.id,
            m.date,
            m.is_outgoing,
            coalesce(m.sender_name, '') as sender_name,
            coalesce(m.text_content, '') as text_content,
            bm25(messages_fts) as fts_score
        from messages_fts
        join messages m on m.rowid = messages_fts.rowid
        where messages_fts match ?
    """
    params: list[Any] = [match_query]
    if time_range:
        sql += " and m.date >= ? and m.date <= ?"
        params.extend([time_range.get("start", 0), time_range.get("end", 9_999_999_999)])
    sql += """
        order by bm25(messages_fts)
        limit ?
    """
    params.append(limit)
    return conn.execute(sql, params).fetchall()


def fetch_sender_hits(
    conn: sqlite3.Connection,
    query: str,
    hints: list[str],
    query_context: dict[str, Any],
    time_range: Optional[dict[str, Any]],
    limit: int = 120,
) -> list[sqlite3.Row]:
    scoped_terms = query_context.get("scopedTerms", [])
    name_tokens = extract_name_tokens([query, *hints])
    sender_terms = list(dict.fromkeys([*scoped_terms, *name_tokens, *distinct_terms(hints)]))
    if not sender_terms:
        return []

    conn.row_factory = sqlite3.Row
    clauses: list[str] = []
    params: list[Any] = []
    for term in sender_terms:
        clauses.append("lower(coalesce(sender_name, '')) like ?")
        params.append(f"%{normalize(term)}%")

    sql = f"""
        select
            chat_id,
            id,
            date,
            is_outgoing,
            coalesce(sender_name, '') as sender_name,
            coalesce(text_content, '') as text_content,
            0.0 as fts_score
        from messages
        where ({' or '.join(clauses)})
    """
    if time_range:
        sql += " and date >= ? and date <= ?"
        params.extend([time_range.get("start", 0), time_range.get("end", 9_999_999_999)])
    sql += " order by date desc limit ?"
    params.append(limit)
    return conn.execute(sql, params).fetchall()


def merge_hits(*hit_lists: list[sqlite3.Row]) -> list[sqlite3.Row]:
    by_key: dict[tuple[int, int], sqlite3.Row] = {}
    for hits in hit_lists:
        for row in hits:
            key = (int(row["chat_id"]), int(row["id"]))
            existing = by_key.get(key)
            if existing is None or float(row["fts_score"] or 0) > float(existing["fts_score"] or 0):
                by_key[key] = row
    return list(by_key.values())


def row_score(row: sqlite3.Row, query: str, hints: list[str], variant: str, query_context: dict[str, Any]) -> float:
    text = normalize(row["text_content"] or "")
    sender = normalize(row["sender_name"] or "")
    combined = f"{sender} {text}".strip()
    tokens = tokenize(query) + [token for phrase in hints for token in tokenize(phrase)]
    token_matches = sum(1 for token in tokens if token in combined)
    phrase_matches = sum(1 for phrase in phraseify(hints) if phrase in combined)
    sender_anchor_terms = query_context.get("senderFallbackTerms") or query_context.get("scopedTerms", [])
    sender_matches = sum(1 for token in sender_anchor_terms if token in sender)
    fts_component = -float(row["fts_score"]) if row["fts_score"] is not None else 0.0
    recency = float(row["date"]) / 10_000_000_000
    outgoing_bonus = 0.15 if row["is_outgoing"] else 0.0

    score = (
        fts_component * 2.5
        + token_matches * 3.0
        + phrase_matches * 8.0
        + sender_matches * 10.0
        + recency
        + outgoing_bonus
    )

    if variant == "focus_chat_v2":
        if "decide" in normalize(query) or "decision" in normalize(query):
            if any(word in text for word in ["decided", "decision", "aligned", "we thought", "we have decided"]):
                score += 5.0
        if "summary" in normalize(query) or "summarize" in normalize(query):
            if any(word in text for word in ["summary", "overview", "lineardigest", "full picture", "bottom line"]):
                score += 3.0
        if any(word in normalize(query) for word in ["last week", "last month", "week of", "after the call"]):
            score += 1.0
    if variant in {"focus_chat_v5", "focus_chat_v6"}:
        if sender_matches:
            score += 12.0
        if query_context.get("scopedTerms") and not query_context.get("topicTerms"):
            score += 2.0
        if any(word in text for word in ["few things", "confirm", "budget", "speakers", "builders"]):
            score += 2.5

    return score


def group_chat_candidates(
    hits: list[sqlite3.Row],
    query: str,
    hints: list[str],
    variant: str,
    query_context: dict[str, Any],
    time_range: Optional[dict[str, Any]] = None,
) -> list[dict[str, Any]]:
    query_terms = set(query_context.get("queryTerms", safe_fts_terms(query)))
    hint_terms = set(distinct_terms(hints))
    hint_phrases = phraseify(hints)
    name_tokens = set(extract_name_tokens([query, *hints]))
    sender_anchor_terms = set(query_context.get("senderFallbackTerms", []))
    grouped: dict[int, list[dict[str, Any]]] = defaultdict(list)
    for row in hits:
        text = normalize(row["text_content"] or "")
        sender = normalize(row["sender_name"] or "")
        combined = f"{sender} {text}".strip()
        matched_query_terms = {token for token in query_terms if token in combined}
        matched_hint_terms = {token for token in hint_terms if token in combined}
        matched_name_tokens = {token for token in name_tokens if token in combined}
        matched_sender_anchor_terms = {token for token in sender_anchor_terms if token in sender}
        matched_body_anchor_terms = {token for token in sender_anchor_terms if token in text}
        grouped[int(row["chat_id"])].append(
            {
                "message_id": int(row["id"]),
                "chat_id": int(row["chat_id"]),
                "date": float(row["date"]),
                "is_outgoing": bool(row["is_outgoing"]),
                "sender_name": row["sender_name"],
                "text_content": row["text_content"],
                "score": row_score(row, query, hints, variant, query_context),
                "matched_query_terms": matched_query_terms,
                "matched_hint_terms": matched_hint_terms,
                "matched_hint_phrases": {phrase for phrase in hint_phrases if phrase in combined},
                "matched_name_tokens": matched_name_tokens,
                "matched_sender_anchor_terms": matched_sender_anchor_terms,
                "matched_body_anchor_terms": matched_body_anchor_terms,
                "has_joint_anchor": bool(matched_name_tokens) and bool((matched_query_terms | matched_hint_terms) - matched_name_tokens),
                "in_time_range": within_range(float(row["date"]), time_range),
            }
        )

    candidates: list[dict[str, Any]] = []
    for chat_id, rows in grouped.items():
        rows.sort(key=lambda row: (row["score"], row["date"]), reverse=True)
        best = rows[0]
        matched_query_terms = set().union(*(row["matched_query_terms"] for row in rows))
        matched_hint_terms = set().union(*(row["matched_hint_terms"] for row in rows))
        matched_hint_phrases = set().union(*(row["matched_hint_phrases"] for row in rows))
        matched_name_tokens = set().union(*(row["matched_name_tokens"] for row in rows))
        in_range_hits = sum(1 for row in rows if row["in_time_range"])
        sender_anchor_hits = sum(1 for row in rows if row["matched_sender_anchor_terms"])
        recent_sender_anchor_hits = sum(
            1 for row in rows if row["in_time_range"] and row["matched_sender_anchor_terms"]
        )
        recent_substantive_anchor_hits = sum(
            1
            for row in rows
            if row["in_time_range"]
            and row["matched_sender_anchor_terms"]
            and len((row["text_content"] or "").strip()) >= 18
        )
        unanchored_scoped_mentions = sum(
            1
            for row in rows
            if row["matched_body_anchor_terms"] and not row["matched_sender_anchor_terms"]
        )
        best_joint_anchor = max(1 if row["has_joint_anchor"] else 0 for row in rows)
        best_row_hint_terms = max(len(row["matched_hint_terms"]) for row in rows)

        aggregate = best["score"] * 1.15
        aggregate += sum(max(0.0, row["score"]) for row in rows[1:3]) * 0.08
        aggregate += len(matched_query_terms) * 5.0
        aggregate += len(matched_hint_terms) * 7.0
        aggregate += len(matched_hint_phrases) * 9.0
        aggregate += len(matched_name_tokens) * 6.0
        aggregate += best_joint_anchor * 12.0
        aggregate += best_row_hint_terms * 2.5
        aggregate += min(in_range_hits, 4) * 3.0
        aggregate += min(sender_anchor_hits, 3) * 12.0
        aggregate += min(recent_sender_anchor_hits, 3) * 10.0
        aggregate += min(recent_substantive_anchor_hits, 3) * 14.0
        aggregate += min(len(rows), 4) * 0.25

        if query_terms and len(matched_query_terms) < max(1, min(2, len(query_terms))):
            aggregate -= 10.0
        if hint_terms and len(matched_hint_terms) == 0:
            aggregate -= 15.0
        if name_tokens and best_joint_anchor == 0:
            aggregate -= 25.0
        if sender_anchor_terms and sender_anchor_hits == 0:
            aggregate -= 30.0
        aggregate -= unanchored_scoped_mentions * 4.0
        if variant in {"focus_chat_v5", "focus_chat_v6"} and query_context.get("scopedTerms") and matched_name_tokens:
            aggregate += 18.0
            if not query_context.get("topicTerms"):
                aggregate += 6.0

        candidates.append(
            {
                "chat_id": chat_id,
                "score": aggregate,
                "top_hits": rows[:8],
                "best_joint_anchor": best_joint_anchor,
                "best_row_hint_terms": best_row_hint_terms,
            }
        )
    candidates.sort(key=lambda item: item["score"], reverse=True)
    return candidates


def within_range(date_value: float, time_range: Optional[dict[str, Any]]) -> bool:
    if not time_range:
        return True
    start = time_range.get("start")
    end = time_range.get("end")
    if start is not None and date_value < float(start):
        return False
    if end is not None and date_value > float(end):
        return False
    return True


def load_supporting_messages(
    conn: sqlite3.Connection,
    chat_id: int,
    top_hits: list[dict[str, Any]],
    time_range: Optional[dict[str, Any]],
    limit: int = 8,
) -> list[dict[str, Any]]:
    message_ids = [hit["message_id"] for hit in top_hits]
    if not message_ids:
        return []
    placeholders = ",".join("?" for _ in message_ids)
    conn.row_factory = sqlite3.Row
    rows = conn.execute(
        f"""
        select id, chat_id, date, is_outgoing, coalesce(sender_name, '') as sender_name, coalesce(text_content, '') as text_content
        from messages
        where chat_id = ? and id in ({placeholders})
        order by date asc
        """,
        (chat_id, *message_ids)
    ).fetchall()
    messages = [
        {
            "message_id": int(row["id"]),
            "chat_id": int(row["chat_id"]),
            "date": float(row["date"]),
            "is_outgoing": bool(row["is_outgoing"]),
            "sender_name": row["sender_name"],
            "text": re.sub(r"\s+", " ", row["text_content"]).strip(),
        }
        for row in rows
        if within_range(float(row["date"]), time_range)
    ]
    if messages:
        if len(messages) >= min(4, limit):
            return messages[:limit]

        anchor_start = min(message["date"] for message in messages)
        anchor_end = max(message["date"] for message in messages)
        nearby_rows = conn.execute(
            """
            select id, chat_id, date, is_outgoing, coalesce(sender_name, '') as sender_name, coalesce(text_content, '') as text_content
            from messages
            where chat_id = ? and date between ? and ?
            order by date asc
            limit 24
            """,
            (chat_id, anchor_start - 1800, anchor_end + 1800)
        ).fetchall()
        expanded = [
            {
                "message_id": int(row["id"]),
                "chat_id": int(row["chat_id"]),
                "date": float(row["date"]),
                "is_outgoing": bool(row["is_outgoing"]),
                "sender_name": row["sender_name"],
                "text": re.sub(r"\s+", " ", row["text_content"]).strip(),
            }
            for row in nearby_rows
            if within_range(float(row["date"]), time_range)
        ]
        deduped: dict[int, dict[str, Any]] = {message["message_id"]: message for message in messages}
        for message in expanded:
            deduped[message["message_id"]] = message
        return sorted(deduped.values(), key=lambda row: row["date"])

    # Fallback: load latest bounded messages in range if top hits all got filtered out.
    fallback_rows = conn.execute(
        """
        select id, chat_id, date, is_outgoing, coalesce(sender_name, '') as sender_name, coalesce(text_content, '') as text_content
        from messages
        where chat_id = ?
        order by date desc
        limit 20
        """,
        (chat_id,)
    ).fetchall()
    fallback = [
        {
            "message_id": int(row["id"]),
            "chat_id": int(row["chat_id"]),
            "date": float(row["date"]),
            "is_outgoing": bool(row["is_outgoing"]),
            "sender_name": row["sender_name"],
            "text": re.sub(r"\s+", " ", row["text_content"]).strip(),
        }
        for row in fallback_rows
        if within_range(float(row["date"]), time_range)
    ]
    fallback.sort(key=lambda row: row["date"])
    return fallback[-limit:]


def supporting_message_score(message: dict[str, Any], query: str, hints: list[str]) -> float:
    text = normalize(message["text"])
    sender = normalize(message.get("sender_name", ""))
    combined = f"{sender} {text}".strip()
    query_terms = set(safe_fts_terms(query))
    hint_terms = set(distinct_terms(hints))
    hint_phrases = phraseify(hints)
    score = len({token for token in query_terms if token in combined}) * 5.0
    score += len({token for token in hint_terms if token in combined}) * 7.0
    score += len({phrase for phrase in hint_phrases if phrase in combined}) * 10.0
    if any(word in text for word in ["summary", "overview", "bottom line", "full picture", "decided", "thought we", "main gaps"]):
        score += 4.0
    if len(text) < 90 and any(
        text.startswith(prefix)
        for prefix in ["check ", "tell ", "digging into it", "hetzner se compare", "what's the context"]
    ):
        score -= 14.0
    if len(text) < 16:
        score -= 8.0
    score += min(len(text), 500) / 250.0
    return score


def summarize_messages(messages: list[dict[str, Any]], variant: str, query: str, hints: list[str]) -> str:
    if not messages:
        return "No clear local summary context found."
    ranked = list(messages)
    if variant in {"focus_chat_v4", "focus_chat_v5"}:
        ranked.sort(
            key=lambda message: (
                supporting_message_score(message, query, hints),
                message["date"]
            ),
            reverse=True
        )
        strong = [
            message
            for message in ranked
            if supporting_message_score(message, query, hints) >= 8.0
        ]
        ranked = sorted((strong or ranked[:4])[:4], key=lambda message: message["date"])
    elif variant in {"focus_chat_v3"}:
        ranked.sort(
            key=lambda message: (
                supporting_message_score(message, query, hints),
                message["date"]
            ),
            reverse=True
        )
        ranked = sorted(ranked[:6], key=lambda message: message["date"])
    else:
        ranked = ranked[:4]

    lines = []
    clip = 1200 if variant in {"focus_chat_v4", "focus_chat_v5"} else 700 if variant == "focus_chat_v3" else 260
    for message in ranked:
        text = message["text"]
        if len(text) > clip:
            text = text[: clip - 3] + "..."
        lines.append(text)
    if variant in {"focus_chat_v2", "focus_chat_v3", "focus_chat_v4", "focus_chat_v5"}:
        return " • ".join(lines)
    return " ".join(lines)


def fact_group_coverage(summary_text: str, fact_groups: list[list[str]]) -> tuple[int, int]:
    normalized = normalize(summary_text)
    matched = 0
    for group in fact_groups:
        if any(normalize(phrase) in normalized for phrase in group):
            matched += 1
    return matched, len(fact_groups)


def forbidden_hits(summary_text: str, forbidden_phrases: list[str]) -> list[str]:
    normalized = normalize(summary_text)
    return [phrase for phrase in forbidden_phrases if normalize(phrase) in normalized]


def evaluate_entry(entry: dict[str, Any], conn: sqlite3.Connection, variant: str) -> dict[str, Any]:
    query_context = build_query_context(entry["query"])
    effective_range = effective_time_range(entry.get("timeRange"), query_context)
    fts_hits = fetch_fts_hits(
        conn,
        entry["query"],
        entry.get("retrievalHints", []),
        query_context,
        effective_range,
    )
    sender_hits = fetch_sender_hits(
        conn,
        entry["query"],
        entry.get("retrievalHints", []),
        query_context,
        effective_range,
    )
    include_sender_hits = (
        variant == "focus_chat_v5"
        or (
            variant in {"focus_chat_v4", "focus_chat_v6"}
            and bool(query_context.get("senderFallbackTerms"))
        )
    )
    hits = merge_hits(fts_hits, sender_hits if include_sender_hits else [])
    candidates = group_chat_candidates(
        hits,
        entry["query"],
        entry.get("retrievalHints", []),
        variant,
        query_context,
        effective_range,
    )
    top_candidate = candidates[0] if candidates else None
    name_tokens = extract_name_tokens([entry["query"], *entry.get("retrievalHints", [])])
    if (
        variant == "focus_chat_v4"
        and top_candidate is not None
        and name_tokens
        and not (query_context.get("scopedTerms") and not query_context.get("topicTerms"))
        and top_candidate["best_joint_anchor"] == 0
        and top_candidate["best_row_hint_terms"] < 4
    ):
        focus_chat_id = None
    else:
        focus_chat_id = top_candidate["chat_id"] if top_candidate else None
    top3_chat_ids = [candidate["chat_id"] for candidate in candidates[:3]]

    expected_kind = entry["expectedKind"]
    expected_chats = set(entry.get("expectedChatIds", []))

    if expected_kind == "no_result":
        supporting_messages: list[dict[str, Any]] = []
        summary_text = "No clear local summary context found." if focus_chat_id is None else summarize_messages(
            load_supporting_messages(conn, focus_chat_id, candidates[0]["top_hits"], effective_range, limit=8),
            variant,
            entry["query"],
            entry.get("retrievalHints", []),
        )
        return {
            "id": entry["id"],
            "query": entry["query"],
            "expectedKind": expected_kind,
            "focusChatId": focus_chat_id,
            "focusTop1Matched": focus_chat_id is None,
            "focusTop3Matched": focus_chat_id is None,
            "supportingMatched": len(supporting_messages) == 0,
            "factCoverage": {
                "matched": 0,
                "total": 0
            },
            "forbiddenHits": forbidden_hits(summary_text, entry.get("forbiddenPhrases", [])),
            "summaryText": summary_text,
            "supportingMessages": supporting_messages,
            "why": entry["why"]
        }

    focus_top1 = focus_chat_id in expected_chats
    focus_top3 = any(chat_id in expected_chats for chat_id in top3_chat_ids)
    supporting_messages = load_supporting_messages(
        conn,
        focus_chat_id if focus_chat_id is not None else 0,
        candidates[0]["top_hits"] if candidates else [],
        effective_range,
        limit=8
    ) if focus_chat_id is not None else []
    summary_text = summarize_messages(supporting_messages, variant, entry["query"], entry.get("retrievalHints", []))
    matched_facts, total_facts = fact_group_coverage(summary_text, entry.get("requiredFactGroups", []))
    supporting_ids = {message["message_id"] for message in supporting_messages}
    expected_supporting = set(entry.get("supportingMessageIds", []))
    supporting_matched = bool(supporting_ids & expected_supporting) if expected_supporting else True

    return {
        "id": entry["id"],
        "query": entry["query"],
        "expectedKind": expected_kind,
        "focusChatId": focus_chat_id,
        "focusTop1Matched": focus_top1,
        "focusTop3Matched": focus_top3,
        "supportingMatched": supporting_matched,
        "factCoverage": {
            "matched": matched_facts,
            "total": total_facts
        },
        "forbiddenHits": forbidden_hits(summary_text, entry.get("forbiddenPhrases", [])),
        "summaryText": summary_text,
        "supportingMessages": supporting_messages,
        "why": entry["why"]
    }


def score_variant(entries: list[dict[str, Any]], db: Path, variant: str) -> dict[str, Any]:
    with sqlite3.connect(db) as conn:
        results = [evaluate_entry(entry, conn, variant) for entry in entries]

    focus_top1 = sum(1 for row in results if row["focusTop1Matched"])
    focus_top3 = sum(1 for row in results if row["focusTop3Matched"])
    supporting = sum(1 for row in results if row["supportingMatched"])
    fact_numerator = sum(row["factCoverage"]["matched"] for row in results)
    fact_denominator = sum(row["factCoverage"]["total"] for row in results)
    clean_outputs = sum(1 for row in results if not row["forbiddenHits"])
    strict_pass = sum(
        1
        for row in results
        if row["focusTop1Matched"]
        and row["supportingMatched"]
        and row["factCoverage"]["matched"] == row["factCoverage"]["total"]
        and not row["forbiddenHits"]
    )

    return {
        "name": variant,
        "summary": {
            "queryCount": len(results),
            "focusTop1Accuracy": focus_top1 / len(results) if results else 0.0,
            "focusTop3Accuracy": focus_top3 / len(results) if results else 0.0,
            "supportingCoverage": supporting / len(results) if results else 0.0,
            "factCoverage": fact_numerator / fact_denominator if fact_denominator else 0.0,
            "cleanOutputRate": clean_outputs / len(results) if results else 0.0,
            "strictPassRate": strict_pass / len(results) if results else 0.0
        },
        "results": results
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Benchmark script-only summary answer quality against a grounded oracle.")
    parser.add_argument("--oracle", type=Path, default=DEFAULT_ORACLE)
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--variants", nargs="*", default=["focus_chat_v1", "focus_chat_v2", "focus_chat_v3", "focus_chat_v4", "focus_chat_v5", "focus_chat_v6"])
    args = parser.parse_args()

    oracle = load_oracle(args.oracle)
    leaderboard = [score_variant(oracle["entries"], args.db, variant) for variant in args.variants]
    leaderboard.sort(
        key=lambda row: (
            -row["summary"]["strictPassRate"],
            -row["summary"]["focusTop1Accuracy"],
            -row["summary"]["factCoverage"]
        )
    )

    print(json.dumps({
        "oracle": str(args.oracle),
        "db": str(args.db),
        "leaderboard": leaderboard
    }, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
