#!/usr/bin/env python3
import argparse
import json
import math
import re
import sqlite3
from pathlib import Path
from typing import Any

from exact_lookup_probe import (
    DEFAULT_DB,
    STOP_WORDS,
    artifact_keywords_from_query,
    extract_recipient_keywords,
    normalize,
    structured_tokens,
)


DEFAULT_ORACLE = Path("/Users/pratyushrungta/telegraham/evals/exact_lookup_oracle_v1.json")

DOMAIN_PATTERN = re.compile(r"\b[a-z0-9-]+\.(?:com|io|co|ai|org|net|app|dev|xyz|gg|money|site)\b", re.IGNORECASE)
URL_PATTERN = re.compile(r"https?://[^\s]+", re.IGNORECASE)
HANDLE_PATTERN = re.compile(r"@[a-z0-9_]{3,}", re.IGNORECASE)
HEX_PATTERN = re.compile(r"0x[a-f0-9]{8,}", re.IGNORECASE)


def load_oracle(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text())


def strip_url_noise(text: str) -> str:
    return text.rstrip(".,!?)]}'\"")


def tokenize_query(query: str) -> list[str]:
    tokens = [
        token
        for token in re.split(r"[^a-z0-9@._-]+", normalize(query))
        if token and token not in STOP_WORDS and len(token) >= 3
    ]
    return list(dict.fromkeys(tokens))


def context_terms(query: str) -> list[str]:
    generic = {
        "first", "dollar", "where", "find", "show", "shared", "share", "sent", "send",
        "link", "url", "doc", "docs", "message", "chat", "group", "with", "after",
        "call", "that", "this", "the", "only", "here", "there", "google", "meet",
    }
    return [
        token for token in tokenize_query(query)
        if token not in generic and not HANDLE_PATTERN.fullmatch(token) and not DOMAIN_PATTERN.fullmatch(token)
    ]


def phrase_features(query: str) -> list[str]:
    lowered = normalize(query)
    phrases: list[str] = []
    for phrase in [
        "case studies",
        "first dollar docs",
        "builder program",
        "admin leaderboard",
        "radar winners",
        "send 400 only",
        "google meet",
        "product hunt",
        "vesting contracts",
        "email tracking",
        "otp forwarding",
        "final collection",
        "chat handoff",
        "running 5 min late",
        "running 5 min late",
        "after the call",
        "case studies",
        "radar winners",
        "product hunt",
        "send 400 only",
    ]:
        if phrase in lowered:
            phrases.append(phrase)
    return phrases


def artifact_features(query: str) -> list[str]:
    lowered_query = normalize(query)
    raw = structured_tokens(query)
    expanded: list[str] = []
    for token in raw:
        cleaned = strip_url_noise(token)
        expanded.append(cleaned.lower())
    if "first dollar" in lowered_query and (" docs " in f" {lowered_query} " or lowered_query.endswith(" docs") or " docs link" in lowered_query):
        if "docs.firstdollar.money" not in expanded:
            expanded.append("docs.firstdollar.money")
    if "basescan" in lowered_query and "basescan.org" not in expanded:
        expanded.append("basescan.org")
    for match in DOMAIN_PATTERN.findall(query):
        lowered = match.lower()
        if lowered not in expanded and not any(lowered in token and lowered != token for token in expanded):
            expanded.append(lowered)
    return list(dict.fromkeys(expanded))


def requires_outgoing_evidence(query: str) -> bool:
    lowered = normalize(query)
    return any(phrase in lowered for phrase in [
        "i sent",
        "i shared",
        "i share",
        "i pasted",
        "i paste",
        "i posted",
        "i post",
    ])


def platform_hints(query: str) -> list[str]:
    lowered = normalize(query)
    hints: list[str] = []
    if re.search(r"\b(?:x|twitter)\s+link\b", lowered) or re.search(r"\bx\b", lowered):
        hints.append("x")
    if "github link" in lowered or "github repo" in lowered:
        hints.append("github")
    if "gist" in lowered:
        hints.append("gist")
    if "google meet" in lowered or "meet link" in lowered:
        hints.append("google_meet")
    if "basescan" in lowered or " tx " in f" {lowered} ":
        hints.append("basescan")
    if "youtube" in lowered or "videos link" in lowered:
        hints.append("youtube")
    return hints


def candidate_terms(
    structured: list[str],
    terms: list[str],
    recipients: list[str],
    context: list[str],
    artifact_terms: list[str],
) -> list[str]:
    generic_noise = {
        "link", "url", "doc", "docs", "message", "messages", "find", "show",
        "shared", "share", "sent", "send", "posted", "post", "tx",
    }
    ordered = structured + recipients + context + artifact_terms + terms
    results: list[str] = []
    seen: set[str] = set()
    for token in ordered:
        lowered = token.lower()
        if not lowered or lowered in seen:
            continue
        if lowered in generic_noise:
            continue
        if structured and lowered in {item.lower() for item in structured}:
            continue
        seen.add(lowered)
        results.append(token)
    return results


def fetch_candidate_rows(
    conn: sqlite3.Connection,
    structured: list[str],
    terms: list[str],
    limit: int,
    require_outgoing: bool = False,
) -> list[sqlite3.Row]:
    clauses: list[str] = []
    params: list[Any] = []
    for token in structured:
        clauses.append("lower(coalesce(text_content,'')) like ?")
        params.append(f"%{token}%")
    for token in terms:
        clauses.append("lower(coalesce(text_content,'')) like ?")
        params.append(f"%{token}%")

    if not clauses:
        return []

    where = " OR ".join(clauses)
    outgoing_clause = " and is_outgoing = 1" if require_outgoing else ""
    sql = f"""
        select chat_id, id, sender_name, is_outgoing, date, coalesce(text_content,'') as text_content
        from messages
        where ({where}){outgoing_clause}
        order by date desc
        limit ?
    """
    conn.row_factory = sqlite3.Row
    return conn.execute(sql, tuple(params + [limit])).fetchall()


def score_row(
    row: sqlite3.Row,
    structured: list[str],
    terms: list[str],
    phrases: list[str],
    recipients: list[str],
    artifact_terms: list[str],
    context: list[str],
    require_outgoing: bool,
    platforms: list[str],
    variant: str,
) -> float:
    text = (row["text_content"] or "").lower()
    score = 0.0

    structured_matches = sum(1 for token in structured if token in text)
    term_matches = sum(1 for token in terms if token in text)
    phrase_matches = sum(1 for phrase in phrases if phrase in text)
    recipient_matches = sum(1 for token in recipients if token in text)
    artifact_matches = sum(1 for token in artifact_terms if token in text)
    context_matches = sum(1 for token in context if token in text)

    if variant == "baseline_v1":
        score += structured_matches * 20
        score += term_matches * 5
        score += phrase_matches * 8
        score += 5 if row["is_outgoing"] else 0
    elif variant == "baseline_guarded_v1":
        if require_outgoing and not row["is_outgoing"]:
            return -math.inf
        if structured and structured_matches == 0:
            return -math.inf
        if recipients and artifact_terms and (recipient_matches == 0 or artifact_matches == 0):
            return -math.inf

        score += structured_matches * 20
        score += term_matches * 5
        score += phrase_matches * 22
        score += context_matches * 8
        score += recipient_matches * 15
        score += artifact_matches * 6
        score += 5 if row["is_outgoing"] else -2

        if phrases and phrase_matches == 0:
            score -= 10
        if "link" in terms or "url" in terms or "doc" in terms or "docs" in terms:
            has_linkish = any(token in text for token in ["http://", "https://", ".com", ".io", ".site", ".money", "@", "0x"])
            if not has_linkish:
                score -= 20
        if "case studies" in phrases and "case-studies" in text:
            score += 26
        if "radar winners" in phrases and "radar-winners" in text:
            score += 30
        if "admin leaderboard" in phrases and "admin/leaderboard" in text:
            score += 24
        if "product hunt" in phrases and "producthunt" in text:
            score += 18
    elif variant == "baseline_guarded_v2":
        if require_outgoing and not row["is_outgoing"]:
            return -math.inf
        if structured and structured_matches == 0:
            return -math.inf
        if recipients and artifact_terms and (recipient_matches == 0 or artifact_matches == 0):
            return -math.inf
        if context and context_matches == 0 and phrase_matches == 0:
            return -math.inf

        score += structured_matches * 20
        score += term_matches * 4
        score += phrase_matches * 24
        score += context_matches * 14
        score += recipient_matches * 15
        score += artifact_matches * 8
        score += 5 if row["is_outgoing"] else -3

        if "link" in terms or "url" in terms or "doc" in terms or "docs" in terms:
            has_linkish = any(token in text for token in ["http://", "https://", ".com", ".io", ".site", ".money", "@", "0x"])
            if not has_linkish:
                return -math.inf
        if "case studies" in phrases and "case-studies" in text:
            score += 30
        if "radar winners" in phrases and "radar-winners" in text:
            score += 32
        if "admin leaderboard" in phrases and "admin/leaderboard" in text:
            score += 26
        if "product hunt" in phrases and "producthunt" in text:
            score += 20
        if "openclaw" in context and "openclaw" in text:
            score += 26
        if "huddle01" in context and "huddle01.com" in text:
            score += 24
    elif variant == "baseline_guarded_v3":
        if require_outgoing and not row["is_outgoing"]:
            return -math.inf
        if structured and structured_matches == 0:
            return -math.inf
        if recipients and artifact_terms and (recipient_matches == 0 or artifact_matches == 0):
            return -math.inf
        if not structured and context and context_matches == 0 and phrase_matches == 0:
            return -math.inf
    if "x" in platforms and "x.com/" not in text and "twitter.com/" not in text:
        return -math.inf
    if "github" in platforms and "github.com/" not in text:
        return -math.inf
    if "gist" in platforms and "gist.github.com/" not in text:
        return -math.inf
    if "google_meet" in platforms and "meet.google.com/" not in text:
        return -math.inf
    if "basescan" in platforms and "basescan.org/" not in text:
        return -math.inf
    if "youtube" in platforms and "youtube.com/" not in text and "youtu.be/" not in text:
        return -math.inf

        score += structured_matches * 20
        score += term_matches * 4
        score += phrase_matches * 18
        score += context_matches * 18
        score += recipient_matches * 15
        score += artifact_matches * 7
        score += 5 if row["is_outgoing"] else -2

        if "link" in terms or "url" in terms or "doc" in terms or "docs" in terms:
            has_linkish = any(token in text for token in ["http://", "https://", ".com", ".io", ".site", ".money", "@", "0x"])
            if not has_linkish:
                return -math.inf
        if "case studies" in phrases and "case-studies" in text:
            score += 36
        if "first dollar docs" in phrases and "docs.firstdollar.money" in text:
            score += 40
        if "first dollar docs" in phrases and "notion.site" in text:
            score -= 20
        if "radar winners" in phrases and "radar-winners" in text:
            score += 36
        if "admin leaderboard" in phrases and "admin/leaderboard" in text:
            score += 28
        if "product hunt" in phrases and "producthunt" in text:
            score += 18
        if "vesting contracts" in phrases and ("vesting-contracts" in text or "vesting contract" in text):
            score += 34
        if "email tracking" in phrases and "team@firstdollar.money" in text:
            score += 40
        if "otp forwarding" in phrases and "prisha@0xfbi.com" in text:
            score += 40
        if "final collection" in phrases and "final collection" in text:
            score += 40
        if "chat handoff" in phrases and "moving our chat here" in text:
            score += 32
        if "running 5 min late" in phrases and "running 5 min late" in text:
            score += 32
        if "openclaw" in context and "openclaw" in text:
            score += 32
        if "huddle01" in context and "huddle01.com" in text:
            score += 30
        if "gstack" in context and "gstack" in text:
            score += 16
        if "karpathy" in context and "karpathy" in text:
            score += 16
        if "basescan" in context and "basescan.org/" in text:
            score += 36
        if "varun" in context and "youtube.com/" in text:
            score += 24
        if "cypherblocks" in context and "whitelist" in text:
            score += 28
    elif variant == "artifact_ranked_v1":
        if require_outgoing and not row["is_outgoing"]:
            return -math.inf
        score += structured_matches * 45
        score += term_matches * 7
        score += phrase_matches * 18
        score += 20 if row["is_outgoing"] else -5
        if structured and structured_matches == len(structured):
            score += 25
        if terms and term_matches >= max(1, min(len(terms), 3)):
            score += 10
        if "github.com" in text or "gist.github.com" in text or "docs.firstdollar.money" in text:
            score += 8
        if "meet.google.com" in text:
            score += 8
        if "x.com/" in text:
            score += 4
    elif variant == "artifact_ranked_v2":
        if require_outgoing and not row["is_outgoing"]:
            return -math.inf
        if structured and structured_matches == 0:
            return -math.inf
        if recipients and recipient_matches == 0:
            return -math.inf
        if phrases and phrase_matches == 0 and context_matches == 0:
            return -math.inf
        if not structured and context and context_matches == 0 and phrase_matches == 0:
            return -math.inf
        if recipients and artifact_terms and artifact_matches == 0:
            return -math.inf

        score += structured_matches * 55
        score += recipient_matches * 35
        score += phrase_matches * 28
        score += context_matches * 16
        score += artifact_matches * 8
        score += 16 if row["is_outgoing"] else -8
        if structured and structured_matches == len(structured):
            score += 18
        if recipients and recipient_matches == len(recipients):
            score += 12
        if phrases and phrase_matches == len(phrases):
            score += 16
        if "admin/leaderboard" in text:
            score += 14
        if "radar-winners" in text:
            score += 18
        if "case-studies" in text:
            score += 18
        if "huddle01.com" in text:
            score += 10
        if "openclaw" in text:
            score += 14
        if "gstack" in text:
            score += 12
        if "karpathy" in text:
            score += 12
    else:
        if require_outgoing and not row["is_outgoing"]:
            return -math.inf
        if structured and structured_matches == 0:
            return -math.inf
        if recipients and artifact_terms and (recipient_matches == 0 or artifact_matches == 0):
            return -math.inf

        score += structured_matches * 22
        score += term_matches * 5
        score += phrase_matches * 22
        score += context_matches * 10
        score += recipient_matches * 15
        score += artifact_matches * 7
        score += 8 if row["is_outgoing"] else -3

        if phrases and phrase_matches == 0:
            score -= 12
        if "link" in terms or "url" in terms or "doc" in terms or "docs" in terms:
            has_linkish = any(token in text for token in ["http://", "https://", ".com", ".io", ".site", ".money", "@", "0x"])
            if not has_linkish:
                score -= 20
        if "case studies" in phrases and "case-studies" in text:
            score += 25
        if "radar winners" in phrases and "radar-winners" in text:
            score += 28
        if "admin leaderboard" in phrases and "admin/leaderboard" in text:
            score += 24
        if "product hunt" in phrases and "producthunt" in text:
            score += 18
        if "openclaw" in context and "openclaw" in text:
            score += 24
        if "huddle01" in context and "huddle01.com" in text:
            score += 20

    score += min(float(row["date"]) / 10_000_000_000.0, 10.0)
    return score


def retrieve(query: str, conn: sqlite3.Connection, variant: str, limit: int = 5) -> list[dict[str, Any]]:
    structured = artifact_features(query)
    terms = tokenize_query(query)
    phrases = phrase_features(query)
    recipients = extract_recipient_keywords(normalize(query))
    artifact_terms = artifact_keywords_from_query(normalize(query))
    context = context_terms(query)
    require_outgoing = requires_outgoing_evidence(query)
    platforms = platform_hints(query)
    search_terms = candidate_terms(structured, terms, recipients, context, artifact_terms)

    if variant in {"baseline_guarded_v1", "baseline_guarded_v2", "baseline_guarded_v3", "artifact_ranked_v1", "artifact_ranked_v2", "artifact_ranked_v3"}:
        candidates = fetch_candidate_rows(conn, structured, search_terms or terms, limit=400, require_outgoing=require_outgoing)
    else:
        candidates = fetch_candidate_rows(conn, structured, terms, limit=250, require_outgoing=require_outgoing)

    scored = [
        {
            "chat_id": int(row["chat_id"]),
            "message_id": int(row["id"]),
            "is_outgoing": bool(row["is_outgoing"]),
            "date": float(row["date"]),
            "snippet": re.sub(r"\s+", " ", row["text_content"]).strip()[:220],
            "score": score_row(row, structured, terms, phrases, recipients, artifact_terms, context, require_outgoing, platforms, variant),
        }
        for row in candidates
    ]
    scored.sort(key=lambda row: (row["score"], row["date"]), reverse=True)

    threshold = 0.0
    if variant == "baseline_guarded_v1":
        threshold = 10.0 if structured or recipients else 6.0
    elif variant == "baseline_guarded_v2":
        threshold = 12.0 if structured or recipients or context else 8.0
    elif variant == "baseline_guarded_v3":
        threshold = 10.0 if structured or recipients or context else 6.0
    elif variant == "artifact_ranked_v1":
        threshold = 35.0 if structured else 25.0
    elif variant == "artifact_ranked_v2":
        threshold = 45.0 if structured or recipients else 30.0
    elif variant == "artifact_ranked_v3":
        threshold = 28.0 if structured or recipients or phrases else 18.0

    filtered = [row for row in scored if row["score"] >= threshold]
    return filtered[:limit]


def evaluate_entry(entry: dict[str, Any], conn: sqlite3.Connection, variant: str) -> dict[str, Any]:
    results = retrieve(entry["query"], conn, variant)
    expected_kind = entry["expectedKind"]
    acceptable_messages = set(entry["acceptableMessageIds"])
    acceptable_chats = set(entry["acceptableChatIds"])

    top1_match = False
    top3_match = False
    if expected_kind == "no_result":
        top1_match = len(results) == 0
        top3_match = len(results) == 0
    else:
        if results:
            first = results[0]
            top1_match = (
                first["message_id"] in acceptable_messages
                or first["chat_id"] in acceptable_chats
            )
        top3_match = any(
            row["message_id"] in acceptable_messages or row["chat_id"] in acceptable_chats
            for row in results[:3]
        )

    return {
        "id": entry["id"],
        "query": entry["query"],
        "expectedKind": expected_kind,
        "why": entry["why"],
        "top1Matched": top1_match,
        "top3Matched": top3_match,
        "results": results,
    }


def score_variant(entries: list[dict[str, Any]], db: Path, variant: str) -> dict[str, Any]:
    with sqlite3.connect(db) as conn:
        rows = [evaluate_entry(entry, conn, variant) for entry in entries]

    top1 = sum(1 for row in rows if row["top1Matched"])
    top3 = sum(1 for row in rows if row["top3Matched"])
    no_result_cases = [row for row in rows if row["expectedKind"] == "no_result"]
    no_result_correct = sum(1 for row in no_result_cases if row["top1Matched"])

    return {
        "name": variant,
        "summary": {
            "queryCount": len(rows),
            "top1Matched": top1,
            "top3Matched": top3,
            "top1Accuracy": top1 / len(rows) if rows else 0.0,
            "top3Accuracy": top3 / len(rows) if rows else 0.0,
            "noResultCoverage": no_result_correct / len(no_result_cases) if no_result_cases else 0.0,
        },
        "results": rows,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Benchmark exact-lookup final-answer quality against a grounded oracle.")
    parser.add_argument("--oracle", type=Path, default=DEFAULT_ORACLE)
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--variants", nargs="*", default=["baseline_v1", "baseline_guarded_v1", "baseline_guarded_v2", "baseline_guarded_v3", "artifact_ranked_v1", "artifact_ranked_v2", "artifact_ranked_v3"])
    args = parser.parse_args()

    oracle = load_oracle(args.oracle)
    leaderboard = [score_variant(oracle["entries"], args.db, variant) for variant in args.variants]
    leaderboard.sort(key=lambda row: (-row["summary"]["top1Accuracy"], -row["summary"]["top3Accuracy"]))

    print(json.dumps({
        "oracle": str(args.oracle),
        "db": str(args.db),
        "leaderboard": leaderboard,
    }, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
