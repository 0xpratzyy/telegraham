#!/usr/bin/env python3
import argparse
import json
import math
import re
import sqlite3
import subprocess
import tempfile
from collections import defaultdict
from functools import lru_cache
from pathlib import Path
from typing import Any


DEFAULT_DB = Path("/Users/pratyushrungta/Library/Application Support/Pidgy/pidgy.db")
DEFAULT_ORACLE = Path("/Users/pratyushrungta/telegraham/evals/topic_search_oracle_v1.json")
DEFAULT_REPORT_DIR = Path("/Users/pratyushrungta/Library/Application Support/Pidgy/debug/topic_search_bench")

STOP_WORDS = {
    "a", "about", "after", "all", "an", "and", "are", "around", "as", "at", "be", "can",
    "chat", "conversations", "discussion", "discussions", "for", "from", "give", "in",
    "latest", "me", "my", "of", "on", "or", "quick", "recap", "show", "summary", "summarize",
    "tell", "the", "these", "this", "those", "to", "updates", "what", "with",
}

SHORT_KEEPERS = {"bd", "qa", "ui", "ux", "pm"}
TOPIC_GENERIC = {
    "address", "addresses", "agent", "agents", "anthropic", "api", "apollo", "app", "balance", "beta", "blocker", "bounties", "brief", "budget", "builder",
    "campaign", "cloud", "community", "data", "decision", "demo", "deployment",
    "feedback", "final", "first", "fit", "fundraising", "gaps", "gateway", "growth", "hackathon",
    "hiring", "huddle01", "infrastructure", "inner", "integration", "investor", "launch",
    "lead", "market", "marketplace", "mobile", "native", "network", "notion", "notes", "office", "onboarding",
    "openclaw", "proxy", "room",
    "options", "paperclip", "partnership", "partnerships", "planning", "platform",
    "positioning", "portfolio", "product", "profile", "project", "rankings", "radar", "review",
    "skate", "slack", "status", "strategy", "stripe", "sub", "talent", "team", "token", "twitter",
    "updates", "wallet", "whitelist", "whitelisted", "whitelisting", "withdrawals", "claude", "code"
}


def normalize(text: str) -> str:
    return re.sub(r"\s+", " ", text.strip().lower())


def tokenize(text: str) -> list[str]:
    cleaned = normalize(text)
    cleaned = re.sub(r"[^a-z0-9 -]+", " ", cleaned)
    tokens = [
        token
        for token in cleaned.split()
        if token and token not in STOP_WORDS and (len(token) >= 3 or token in SHORT_KEEPERS)
    ]
    return list(dict.fromkeys(tokens))


def name_like_tokens(query: str, hints: list[str]) -> list[str]:
    tokens = tokenize(query)
    return [
        token for token in tokens
        if token.isalpha() and token not in TOPIC_GENERIC and token not in SHORT_KEEPERS
    ]


def build_fts_query(query: str, hints: list[str]) -> str:
    phrases: list[str] = []
    for phrase in [query, *hints]:
        cleaned = normalize(phrase)
        if not cleaned:
            continue
        cleaned = re.sub(r"[^a-z0-9 ]+", " ", cleaned)
        cleaned = re.sub(r"\s+", " ", cleaned).strip()
        if not cleaned:
            continue
        if " " in cleaned:
            phrases.append(f"\"{cleaned}\"")
        else:
            phrases.append(cleaned)

    for token in tokenize(query):
        if token not in phrases:
            phrases.append(token)

    return " OR ".join(dict.fromkeys(phrases))


def load_oracle(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text())


@lru_cache(maxsize=128)
def swift_embed(text: str) -> tuple[float, ...]:
    source = """
import Foundation
import NaturalLanguage

let text = CommandLine.arguments.dropFirst().joined(separator: " ")
guard let embedding = NLEmbedding.sentenceEmbedding(for: .english),
      let vector = embedding.vector(for: text) else {
    fputs("NO_EMBEDDING\\n", stderr)
    exit(1)
}

let payload = vector.map { String($0) }.joined(separator: ",")
print(payload)
"""
    with tempfile.NamedTemporaryFile("w", suffix=".swift", delete=False) as handle:
        handle.write(source)
        path = Path(handle.name)

    try:
        output = subprocess.check_output(
            ["/usr/bin/swift", str(path), *text.split()],
            text=True,
        ).strip()
    finally:
        path.unlink(missing_ok=True)

    return tuple(float(item) for item in output.split(",") if item)


def decode_vector(blob: bytes) -> list[float]:
    if len(blob) % 8 != 0:
        return []
    count = len(blob) // 8
    return list(memoryview(blob).cast("d")[:count])


def cosine_similarity(lhs: list[float], rhs: list[float]) -> float:
    if len(lhs) != len(rhs) or not lhs:
        return -1.0
    dot = 0.0
    lhs_norm = 0.0
    rhs_norm = 0.0
    for left, right in zip(lhs, rhs):
        dot += left * right
        lhs_norm += left * left
        rhs_norm += right * right
    if lhs_norm <= 0 or rhs_norm <= 0:
        return -1.0
    return dot / math.sqrt(lhs_norm * rhs_norm)


def fetch_fts_hits(conn: sqlite3.Connection, query: str, hints: list[str], limit: int) -> list[sqlite3.Row]:
    match_query = build_fts_query(query, hints)
    if not match_query:
        return []
    conn.row_factory = sqlite3.Row
    return conn.execute(
        """
        SELECT
          m.chat_id,
          m.id,
          m.date,
          m.is_outgoing,
          coalesce(m.sender_name, '') AS sender_name,
          coalesce(m.text_content, '') AS text_content,
          bm25(messages_fts) AS raw_bm25
        FROM messages_fts
        JOIN messages AS m ON m.rowid = messages_fts.rowid
        WHERE messages_fts MATCH ?
        ORDER BY bm25(messages_fts)
        LIMIT ?
        """,
        (match_query, limit),
    ).fetchall()


def fetch_vector_hits(
    conn: sqlite3.Connection,
    query_vector: list[float],
    chat_ids: list[int],
    limit: int,
) -> list[dict[str, Any]]:
    if not chat_ids:
        return []

    conn.row_factory = sqlite3.Row
    placeholders = ",".join("?" for _ in chat_ids)
    rows = conn.execute(
        f"""
        SELECT
          e.chat_id,
          e.message_id,
          e.vector,
          coalesce(m.sender_name, '') AS sender_name,
          coalesce(m.text_content, '') AS text_content,
          m.date,
          m.is_outgoing
        FROM embeddings AS e
        JOIN messages AS m ON m.chat_id = e.chat_id AND m.id = e.message_id
        WHERE e.chat_id IN ({placeholders})
        """,
        tuple(chat_ids),
    ).fetchall()

    scored: list[dict[str, Any]] = []
    for row in rows:
        vector = decode_vector(row["vector"])
        if not vector:
            continue
        score = cosine_similarity(query_vector, vector)
        if score <= 0:
            continue
        scored.append(
            {
                "chat_id": int(row["chat_id"]),
                "message_id": int(row["message_id"]),
                "date": float(row["date"]),
                "is_outgoing": bool(row["is_outgoing"]),
                "sender_name": row["sender_name"],
                "text_content": row["text_content"],
                "vector_score": score,
            }
        )

    scored.sort(key=lambda item: (item["vector_score"], item["date"], item["message_id"]), reverse=True)
    return scored[:limit]


def normalize_scores(values: list[float]) -> dict[int, float]:
    if not values:
        return {}
    max_value = max(values)
    if max_value <= 0:
        return {index: 0.0 for index in range(len(values))}
    return {index: max(0.0, min(1.0, values[index] / max_value)) for index in range(len(values))}


def score_message(
    text: str,
    query_terms: list[str],
    hint_terms: list[str],
    hint_phrases: list[str],
    name_tokens: list[str],
) -> tuple[int, int, int, int]:
    normalized = normalize(text)
    query_matches = sum(1 for token in query_terms if token in normalized)
    hint_matches = sum(1 for token in hint_terms if token in normalized)
    phrase_matches = sum(1 for phrase in hint_phrases if phrase in normalized)
    name_matches = sum(1 for token in name_tokens if token in normalized)
    return query_matches, hint_matches, phrase_matches, name_matches


def rank_topic_chats(
    conn: sqlite3.Connection,
    query: str,
    hints: list[str],
    variant: str,
) -> list[dict[str, Any]]:
    query_terms = tokenize(query)
    hint_terms = list(dict.fromkeys(token for hint in hints for token in tokenize(hint)))
    hint_phrases = [normalize(hint) for hint in hints if " " in normalize(hint)]
    name_tokens = name_like_tokens(query, hints)

    fts_hits = fetch_fts_hits(conn, query, hints, limit=250)
    candidate_chat_ids = list(dict.fromkeys(int(row["chat_id"]) for row in fts_hits))[:120]
    query_vector = swift_embed(query)
    vector_hits = fetch_vector_hits(conn, query_vector, chat_ids=candidate_chat_ids, limit=80)

    normalized_fts = normalize_scores([max(0.0, -float(hit["raw_bm25"])) for hit in fts_hits])
    normalized_vec = normalize_scores([float(hit["vector_score"]) for hit in vector_hits])

    by_message: dict[tuple[int, int], dict[str, Any]] = {}

    for index, row in enumerate(fts_hits):
        key = (int(row["chat_id"]), int(row["id"]))
        entry = by_message.setdefault(
            key,
            {
                "chat_id": int(row["chat_id"]),
                "message_id": int(row["id"]),
                "date": float(row["date"]),
                "sender_name": row["sender_name"],
                "text_content": row["text_content"],
                "fts_score": 0.0,
                "vector_score": 0.0,
                "is_outgoing": bool(row["is_outgoing"]),
            },
        )
        entry["fts_score"] = max(entry["fts_score"], normalized_fts[index])

    for index, row in enumerate(vector_hits):
        key = (int(row["chat_id"]), int(row["message_id"]))
        entry = by_message.setdefault(
            key,
            {
                "chat_id": int(row["chat_id"]),
                "message_id": int(row["message_id"]),
                "date": float(row["date"]),
                "sender_name": row["sender_name"],
                "text_content": row["text_content"],
                "fts_score": 0.0,
                "vector_score": 0.0,
                "is_outgoing": bool(row["is_outgoing"]),
            },
        )
        entry["vector_score"] = max(entry["vector_score"], normalized_vec[index])

    grouped: dict[int, list[dict[str, Any]]] = defaultdict(list)
    for message in by_message.values():
        query_matches, hint_matches, phrase_matches, name_matches = score_message(
            message["text_content"],
            query_terms,
            hint_terms,
            hint_phrases,
            name_tokens,
        )
        message["query_matches"] = query_matches
        message["hint_matches"] = hint_matches
        message["phrase_matches"] = phrase_matches
        message["name_matches"] = name_matches
        base = (message["fts_score"] * 0.6) + (message["vector_score"] * 0.4)
        base += query_matches * 0.18
        base += hint_matches * 0.25
        base += phrase_matches * 0.5
        base += name_matches * 0.45
        message["row_score"] = base
        grouped[message["chat_id"]].append(message)

    candidates: list[dict[str, Any]] = []
    for chat_id, messages in grouped.items():
        messages.sort(key=lambda item: (item["row_score"], item["date"]), reverse=True)
        best = messages[0]
        query_coverage = len({token for message in messages for token in query_terms if token in normalize(message["text_content"])})
        hint_coverage = len({token for message in messages for token in hint_terms if token in normalize(message["text_content"])})
        phrase_coverage = len({phrase for message in messages for phrase in hint_phrases if phrase in normalize(message["text_content"])})
        name_coverage = len({token for message in messages for token in name_tokens if token in normalize(message["text_content"])})

        score = best["row_score"] * 1.25
        score += sum(max(0.0, message["row_score"]) for message in messages[1:3]) * 0.12
        score += query_coverage * 0.45
        score += hint_coverage * 0.75
        score += phrase_coverage * 1.2
        score += name_coverage * 0.9
        score += min(len(messages), 4) * 0.05

        if variant == "topic_guarded_v2":
            if query_terms and query_coverage < max(1, min(2, len(query_terms))):
                score -= 1.0
            if hint_terms and hint_coverage == 0 and phrase_coverage == 0:
                score -= 1.5
            if best["fts_score"] == 0 and best["vector_score"] < 0.45:
                score -= 1.0

        if variant == "topic_guarded_v3":
            if query_terms and query_coverage < max(1, min(2, len(query_terms))):
                score -= 1.2
            if hint_terms and hint_coverage == 0 and phrase_coverage == 0:
                score -= 2.0
            if best["fts_score"] == 0 and best["vector_score"] < 0.5:
                score -= 1.2
            if best["query_matches"] == 0 and best["phrase_matches"] == 0:
                score -= 1.2
            if name_tokens and name_coverage == 0:
                score -= 2.0

        candidates.append(
            {
                "chat_id": chat_id,
                "score": score,
                "best_snippet": normalize(best["text_content"])[:220],
                "best_message_id": best["message_id"],
                "best_name_matches": best["name_matches"],
                "best_query_matches": best["query_matches"],
                "best_phrase_matches": best["phrase_matches"],
                "top_messages": messages[:5],
                "query_coverage": query_coverage,
                "hint_coverage": hint_coverage,
                "phrase_coverage": phrase_coverage,
                "name_coverage": name_coverage,
            }
        )

    candidates.sort(key=lambda item: (item["score"], item["top_messages"][0]["date"]), reverse=True)
    return candidates


def should_return_no_result(candidates: list[dict[str, Any]], variant: str) -> bool:
    if not candidates:
        return True
    top = candidates[0]
    if variant == "fts_rollup_v1":
        return False
    if top["score"] < 1.3:
        return True
    if variant == "topic_guarded_v2":
        return top["query_coverage"] == 0
    if variant == "topic_guarded_v3":
        return (
            top["query_coverage"] == 0
            or (top["hint_coverage"] == 0 and top["phrase_coverage"] == 0)
            or (top["name_coverage"] == 0 and any(token in normalize(top["best_snippet"]) for token in ["wallet", "address", "bounty", "mobile"]))
            or (top["name_coverage"] > 0 and top["best_name_matches"] == 0)
            or (top["best_name_matches"] > 0 and top["best_query_matches"] < 2 and top["best_phrase_matches"] == 0)
        )
    return False


def evaluate_entry(conn: sqlite3.Connection, entry: dict[str, Any], variant: str) -> dict[str, Any]:
    candidates = rank_topic_chats(
        conn=conn,
        query=entry["query"],
        hints=entry.get("retrievalHints", []),
        variant=variant,
    )
    if should_return_no_result(candidates, variant):
        candidates = []

    top_ids = [candidate["chat_id"] for candidate in candidates[:3]]
    expected_kind = entry["expectedKind"]
    expected_ids = set(entry.get("expectedChatIds", []))
    snippet_pool = " ".join(
        normalize(message["text_content"])
        for candidate in candidates[:2]
        for message in candidate["top_messages"][:3]
    )
    required_terms = [normalize(term) for term in entry.get("requiredSnippetTerms", [])]
    snippet_ok = not required_terms or any(term in snippet_pool for term in required_terms)

    if expected_kind == "no_result":
        top1_ok = not candidates
        top3_ok = not candidates
        strict_ok = not candidates
    else:
        top1_ok = bool(candidates) and candidates[0]["chat_id"] in expected_ids
        top3_ok = any(chat_id in expected_ids for chat_id in top_ids)
        strict_ok = top1_ok and snippet_ok

    return {
        "id": entry["id"],
        "query": entry["query"],
        "expectedKind": expected_kind,
        "expectedChatIds": sorted(expected_ids),
        "topCandidates": candidates[:3],
        "top1Ok": top1_ok,
        "top3Ok": top3_ok,
        "snippetOk": snippet_ok,
        "strictOk": strict_ok,
    }


def summarize(results: list[dict[str, Any]]) -> dict[str, float]:
    hits = [result for result in results if result["expectedKind"] == "hit"]
    no_results = [result for result in results if result["expectedKind"] == "no_result"]

    def rate(items: list[dict[str, Any]], key: str) -> float:
        if not items:
            return 1.0
        return sum(1 for item in items if item[key]) / len(items)

    return {
        "top1Accuracy": rate(hits, "top1Ok"),
        "top3Accuracy": rate(hits, "top3Ok"),
        "snippetCoverage": rate(hits, "snippetOk"),
        "strictPassRate": rate(results, "strictOk"),
        "noResultCoverage": rate(no_results, "strictOk"),
    }


def markdown_table(report: dict[str, Any]) -> str:
    lines = [
        "| Variant | Top-1 | Top-3 | Snippet | Strict Pass | No Result |",
        "| --- | ---: | ---: | ---: | ---: | ---: |",
    ]
    for variant in report["variants"]:
        metrics = variant["metrics"]
        lines.append(
            "| `{name}` | `{top1:.1%}` | `{top3:.1%}` | `{snippet:.1%}` | `{strict:.1%}` | `{no_result:.1%}` |".format(
                name=variant["name"],
                top1=metrics["top1Accuracy"],
                top3=metrics["top3Accuracy"],
                snippet=metrics["snippetCoverage"],
                strict=metrics["strictPassRate"],
                no_result=metrics["noResultCoverage"],
            )
        )
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Benchmark topic-search chat ranking against a grounded oracle.")
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--oracle", type=Path, default=DEFAULT_ORACLE)
    parser.add_argument(
        "--variants",
        nargs="*",
        default=["fts_rollup_v1", "topic_guarded_v2", "topic_guarded_v3"],
    )
    parser.add_argument("--report-dir", type=Path, default=DEFAULT_REPORT_DIR)
    args = parser.parse_args()

    oracle = load_oracle(args.oracle)
    timestamp = subprocess.check_output(["/bin/date", "+%Y%m%d-%H%M%S"], text=True).strip()
    report_dir = args.report_dir / timestamp
    report_dir.mkdir(parents=True, exist_ok=True)

    variants: list[dict[str, Any]] = []
    with sqlite3.connect(args.db) as conn:
        for variant in args.variants:
            results = [evaluate_entry(conn, entry, variant) for entry in oracle["entries"]]
            variants.append(
                {
                    "name": variant,
                    "metrics": summarize(results),
                    "results": results,
                }
            )

    variants.sort(
        key=lambda item: (
            item["metrics"]["strictPassRate"],
            item["metrics"]["top1Accuracy"],
            item["metrics"]["snippetCoverage"],
        ),
        reverse=True,
    )

    report = {
        "oracle": str(args.oracle),
        "db": str(args.db),
        "variants": variants,
    }
    (report_dir / "report.json").write_text(json.dumps(report, indent=2))
    (report_dir / "leaderboard.md").write_text(markdown_table(report) + "\n")

    print(json.dumps({
        "reportDir": str(report_dir),
        "bestVariant": variants[0]["name"] if variants else None,
        "metrics": variants[0]["metrics"] if variants else {},
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
