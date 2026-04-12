#!/usr/bin/env python3
import argparse
import json
import re
from datetime import datetime, timedelta, timezone
from typing import Any, Optional


BASE_REPLY_SIGNALS = [
    "haven't replied",
    "havent replied",
    "have not replied",
    "didn't reply",
    "didnt reply",
    "did not reply",
    "need to reply",
    "have to reply",
    "who should i reply",
    "who do i have to reply",
    "waiting on me",
    "haven't responded",
    "have not responded",
]

BASE_CRM_SIGNALS = [
    "stale", "inactive", "most active", "top contacts", "top people",
    "warm leads", "investors", "builders", "community", "vendors",
    "friends", "acquaintance", "who do i talk to most"
]

ROUTING_VARIANTS = {
    "current_v1": {
        "reply_signals": BASE_REPLY_SIGNALS,
        "reply_patterns": [],
        "crm_signals": BASE_CRM_SIGNALS,
    },
    "reply_queue_expanded_v1": {
        "reply_signals": BASE_REPLY_SIGNALS + [
            "need my reply",
            "need my response",
            "needs my response",
            "needs my reply",
            "pending my reply",
            "pending my response",
            "owe a reply",
            "owe reply",
            "owe a response",
            "still on me",
            "follow-up from me",
            "follow up from me",
            "need response from me",
            "supposed to respond",
        ],
        "reply_patterns": [
            r"\bneed(?:s)?\b.*\b(my|a)\s+(reply|response)\b",
            r"\b(pending|owe|owed)\b.*\b(reply|response)\b",
            r"\bfollow[\s-]?up\b.*\bfrom me\b",
            r"\bstill\b.*\bon me\b",
            r"\bowe\b.*\brepl(?:y|ies)\b",
            r"\brespond\b.*\bto\b",
        ],
        "crm_signals": BASE_CRM_SIGNALS,
    },
    "relationship_narrow_v1": {
        "reply_signals": BASE_REPLY_SIGNALS,
        "reply_patterns": [],
        "crm_signals": [signal for signal in BASE_CRM_SIGNALS if signal != "community"],
    },
    "product_coverage_v1": {
        "reply_signals": BASE_REPLY_SIGNALS + [
            "need my reply",
            "need my response",
            "needs my response",
            "needs my reply",
            "pending my reply",
            "pending my response",
            "owe a reply",
            "owe reply",
            "owe a response",
            "still on me",
            "follow-up from me",
            "follow up from me",
            "need response from me",
            "supposed to respond",
        ],
        "reply_patterns": [
            r"\bneed(?:s)?\b.*\b(my|a)\s+(reply|response)\b",
            r"\b(pending|owe|owed)\b.*\b(reply|response)\b",
            r"\bfollow[\s-]?up\b.*\bfrom me\b",
            r"\bstill\b.*\bon me\b",
            r"\bowe\b.*\brepl(?:y|ies)\b",
            r"\brespond\b.*\bto\b",
        ],
        "crm_signals": [signal for signal in BASE_CRM_SIGNALS if signal != "community"],
    },
    "product_coverage_v2": {
        "reply_signals": BASE_REPLY_SIGNALS + [
            "need my reply",
            "need my response",
            "needs my response",
            "needs my reply",
            "pending my reply",
            "pending my response",
            "owe a reply",
            "owe reply",
            "owe a response",
            "still on me",
            "follow-up from me",
            "follow up from me",
            "pending follow-up",
            "pending follow up",
            "pending follow-ups",
            "pending follow ups",
            "need response from me",
            "supposed to respond",
            "waiting on my reply",
            "open dms that need a reply",
            "open dms that need my reply",
            "responsible for answering",
            "promise to get back to",
            "promised to get back to",
            "what is on me",
        ],
        "reply_patterns": [
            r"\bneed(?:s)?\b.*\b(my|a)\s+(reply|response)\b",
            r"\b(pending|owe|owed)\b.*\b(reply|response)\b",
            r"\bfollow[\s-]?up\b.*\bfrom me\b",
            r"\b(still|what(?:'s| is)?)\b.*\bon me\b",
            r"\bowe\b.*\brepl(?:y|ies)\b",
            r"\brespond\b.*\bto\b",
            r"\bresponsible\b.*\b(answering|responding)\b",
            r"\bpromis(?:e|ed)\b.*\bget back\b",
            r"\bwaiting\b.*\bmy reply\b",
            r"\bopen dms?\b.*\bneed(?:s)?\b.*\breply\b",
        ],
        "crm_signals": [signal for signal in BASE_CRM_SIGNALS if signal != "community"] + [
            "warmest contacts",
            "strongest investor relationships",
            "best leads",
            "relationship strength",
            "relationship with",
            "warm but not active",
            "talked to most this month",
            "top contacts by relationship",
            "state of my relationship",
        ],
        "crm_patterns": [
            r"\bwho are my warmest contacts\b",
            r"\bwhich people have i talked to most\b",
            r"\bstrongest\b.*\brelationships\b",
            r"\bbest leads\b.*\bnetwork\b",
            r"\brelationships?\b.*\bwarm\b.*\bnot active\b",
            r"\bstate of my relationship\b",
            r"\btop people\b.*\brelationship strength\b",
        ],
        "crm_override_patterns": [
            r"\bcontacts?\b.*\bhaven'?t replied\b.*\bin a while\b",
            r"\bwho\b.*\bhaven'?t replied\b.*\bin a while\b",
        ],
        "summary_signals": [
            "summarize", "summary", "summarise", "recap",
            "what did we decide", "what happened", "what did i discuss",
            "what have we discussed", "latest context", "catch me up",
            "key takeaways", "takeaways from",
        ],
    },
}


def contains_any(phrases: list[str], text: str) -> bool:
    return any(phrase in text for phrase in phrases)


def regex_matches(pattern: str, text: str) -> bool:
    return re.search(pattern, text, flags=re.IGNORECASE) is not None


def normalize(query: str) -> str:
    return query.strip().lower().replace("’", "'")


def infer_scope(normalized: str, active_filter: str = "all") -> tuple[str, bool, list[str]]:
    dm_signals = [
        "only dms", "only dm", "dm only", "dms only", "in dms", "in dm", "just dms", "just dm"
    ]
    group_signals = [
        "only groups", "group only", "groups only", "in groups", "just groups"
    ]

    has_dm_scope = contains_any(dm_signals, normalized)
    has_group_scope = contains_any(group_signals, normalized)
    unsupported: list[str] = []

    if has_dm_scope and has_group_scope:
        unsupported.append("Conflicting scope terms (DMs and groups).")
        return active_filter, False, unsupported
    if has_dm_scope:
        return "dms", True, unsupported
    if has_group_scope:
        return "groups", True, unsupported
    return active_filter, False, unsupported


def infer_reply_constraint(normalized: str, variant: str) -> str:
    config = ROUTING_VARIANTS[variant]
    reply_signals = config["reply_signals"]
    inferred = (
        contains_any(reply_signals, normalized)
        or regex_matches(r"\bhaven'?t\b.*\brepl(?:y|ied)\b", normalized)
        or regex_matches(r"\bwho\b.*\brepl(?:y|ied)\b", normalized)
        or (regex_matches(r"\brespond(?:ed|ing)?\b", normalized) and "who" in normalized)
        or any(regex_matches(pattern, normalized) for pattern in config["reply_patterns"])
    )
    return "pipeline_on_me_only" if inferred else "none"


def infer_family(normalized: str, reply_constraint: str, variant: str) -> str:
    config = ROUTING_VARIANTS[variant]
    crm_override_patterns = config.get("crm_override_patterns", [])
    if any(regex_matches(pattern, normalized) for pattern in crm_override_patterns):
        return "relationship"

    if reply_constraint == "pipeline_on_me_only":
        return "reply_queue"

    summary_signals = config.get("summary_signals", [
        "summarize", "summary", "summarise", "recap",
        "what did we decide", "what happened", "what did i discuss",
        "what have we discussed", "latest context", "catch me up"
    ])
    if contains_any(summary_signals, normalized):
        return "summary"

    crm_signals = config["crm_signals"]
    crm_patterns = config.get("crm_patterns", [])
    if contains_any(crm_signals, normalized) or any(regex_matches(pattern, normalized) for pattern in crm_patterns):
        return "relationship"

    exact_lookup_signals = [
        "where did i share", "where i shared", "where did i send", "where i sent",
        "where did i paste", "where i pasted", "find message with", "find messages with",
        "show messages with", "show message with", "which chat has", "find the message",
        "find this link", "find this url", "where did i post", "where i posted"
    ]
    exact_entity_signals = [
        "wallet address", "contract address", "tx hash", "transaction hash",
        "email address", "telegram username", "twitter handle", "discord handle",
        "link", "url", "domain", "ca ", "contract"
    ]
    artifact_signals = [
        "wallet", "address", "contract", "hash", "link", "url", "domain", "handle", "username"
    ]
    transfer_lookup_signals = [
        "i sent", "i shared", "i pasted", "i posted",
        "sent to", "shared to", "shared with", "posted to", "pasted to",
        "find", "show", "where"
    ]
    has_structured_token = (
        regex_matches(r"\b0x[a-f0-9]{6,}\b", normalized)
        or regex_matches(r"\b[1-9A-HJ-NP-Za-km-z]{24,64}\b", normalized)
        or regex_matches(r"https?://", normalized)
        or regex_matches(r"@[a-z0-9_]{3,}", normalized)
        or regex_matches(r"\b[a-z0-9-]+\.(?:com|io|co|ai|org|net|app|dev|xyz|gg|finance|me|so)\b", normalized)
    )
    has_artifact_transfer_intent = contains_any(artifact_signals, normalized) and contains_any(
        transfer_lookup_signals, normalized
    )
    if (
        contains_any(exact_lookup_signals, normalized)
        or contains_any(exact_entity_signals, normalized)
        or has_structured_token
        or has_artifact_transfer_intent
    ):
        return "exact_lookup"

    return "topic_search"


def preferred_engine(family: str) -> str:
    return {
        "exact_lookup": "message_lookup",
        "topic_search": "semantic_retrieval",
        "reply_queue": "reply_triage",
        "relationship": "graph_crm",
        "summary": "summarize",
    }[family]


def runtime_mode(engine: str) -> str:
    return {
        "message_lookup": "message_search",
        "semantic_retrieval": "semantic_search",
        "summarize": "summary_search",
        "reply_triage": "agentic_search",
        "graph_crm": "unsupported",
    }[engine]


def parse_time_range(normalized: str, now: datetime) -> Optional[dict[str, Any]]:
    if "today" in normalized:
        start = datetime(now.year, now.month, now.day, tzinfo=now.tzinfo)
        end = start + timedelta(hours=23, minutes=59, seconds=59)
        return {"label": "Today", "start": start.isoformat(), "end": end.isoformat()}
    if "yesterday" in normalized:
        target = now - timedelta(days=1)
        start = datetime(target.year, target.month, target.day, tzinfo=now.tzinfo)
        end = start + timedelta(hours=23, minutes=59, seconds=59)
        return {"label": "Yesterday", "start": start.isoformat(), "end": end.isoformat()}
    if "this week" in normalized:
        start = now - timedelta(days=now.weekday())
        start = datetime(start.year, start.month, start.day, tzinfo=now.tzinfo)
        return {"label": "This Week", "start": start.isoformat(), "end": now.isoformat()}
    if "last week" in normalized:
        start = now - timedelta(days=7)
        return {"label": "Last Week", "start": start.isoformat(), "end": now.isoformat()}
    return None


def probe(query: str, variant: str = "current_v1") -> dict[str, Any]:
    normalized = normalize(query)
    if not normalized:
        family = "topic_search"
        engine = preferred_engine(family)
        return {
            "query": query,
            "normalized": normalized,
            "family": family,
            "preferredEngine": engine,
            "mode": runtime_mode(engine),
            "scope": "all",
            "scopeWasExplicit": False,
            "replyConstraint": "none",
            "timeRange": None,
            "parseConfidence": 0.95,
            "unsupportedFragments": [],
        }

    scope, scope_was_explicit, unsupported = infer_scope(normalized)
    reply_constraint = infer_reply_constraint(normalized, variant)
    time_range = parse_time_range(normalized, datetime.now(timezone.utc))
    if contains_any(["before ", "after ", "between ", "except "], normalized):
        unsupported.append("Advanced time operators are not fully supported yet.")

    family = infer_family(normalized, reply_constraint, variant)
    engine = preferred_engine(family)
    confidence = 0.45
    if runtime_mode(engine) == "agentic_search":
        confidence += 0.15
    if scope_was_explicit:
        confidence += 0.15
    if reply_constraint != "none":
        confidence += 0.20
    if time_range is not None:
        confidence += 0.20
    if family == "exact_lookup":
        confidence += 0.10
    if family in {"summary", "relationship"}:
        confidence += 0.08
    confidence -= len(unsupported) * 0.12
    confidence = min(0.99, max(0.05, confidence))

    return {
        "query": query,
        "variant": variant,
        "normalized": normalized,
        "family": family,
        "preferredEngine": engine,
        "mode": runtime_mode(engine),
        "scope": scope,
        "scopeWasExplicit": scope_was_explicit,
        "replyConstraint": reply_constraint,
        "timeRange": time_range,
        "parseConfidence": confidence,
        "unsupportedFragments": sorted(set(unsupported)),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Probe query routing family/engine for a product prompt.")
    parser.add_argument("--variant", default="current_v1", choices=sorted(ROUTING_VARIANTS.keys()))
    parser.add_argument("query")
    args = parser.parse_args()
    print(json.dumps(probe(args.query, variant=args.variant), indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
