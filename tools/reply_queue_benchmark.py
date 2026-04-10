#!/usr/bin/env python3
import argparse
import json
import math
import os
import sys
import time
import urllib.request
import urllib.error
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Any, Optional


APP_SUPPORT = Path.home() / "Library" / "Application Support" / "Pidgy"
DEFAULT_CANDIDATES_PATH = APP_SUPPORT / "debug" / "last_reply_queue_candidates.json"
DEFAULT_RESULTS_PATH = APP_SUPPORT / "debug" / "last_reply_queue_benchmark_results.json"
DEFAULT_API_KEY_PATH = APP_SUPPORT / "credentials" / "com.pidgy.aiApiKey"

# Standard and projected priority rates as of 2026-04-09 from official OpenAI docs/pricing.
PRICING = {
    "gpt-5-mini": {
        "standard": {"input": 0.25, "cached_input": 0.025, "output": 2.00},
        "priority": {"input": 0.45, "cached_input": 0.045, "output": 3.60},
    },
    "gpt-5.4-mini": {
        "standard": {"input": 0.75, "cached_input": 0.075, "output": 4.50},
        "priority": {"input": 1.50, "cached_input": 0.15, "output": 9.00},
    },
    "gpt-5.4-nano": {
        "standard": {"input": 0.20, "cached_input": 0.02, "output": 1.25},
    },
    "gpt-4o-mini": {
        "standard": {"input": 0.15, "cached_input": 0.075, "output": 0.60},
    },
    "gpt-4.1-mini": {
        "standard": {"input": 0.40, "cached_input": 0.10, "output": 1.60},
        "priority": {"input": 0.70, "cached_input": 0.175, "output": 2.80},
    },
}

SYSTEM_PROMPT = """
You triage Telegram chats for a BD/community operator.
Your job is to decide whether the user currently owes a reply in each candidate chat.

You will receive many candidate chats at once. Return exactly one result for every candidate chatId.

Classification rules:
- "on_me": the user clearly owes a reply or follow-up now.
- "on_them": the other side owns the next step, or the user already replied and is waiting.
- "quiet": no active obligation right now.
- "need_more": only use when the provided context is genuinely insufficient to tell.

Key judgment rules:
- Prefer concrete unresolved asks over vague warmth.
- The sender label "[ME]" means the current user sent that message.
- In groups, do NOT mark "on_me" if the ask is clearly aimed at someone else.
- Treat acknowledgements, reactions, celebrations, and thread-closing chatter as "quiet" unless a new ask appears.
- A previous ask that has already been answered or superseded by later messages should not remain "on_me".
- Use supportingMessageIds to point at the messages that justify the decision.
- suggestedAction should be short and practical.

Return exactly one JSON object:
{
  "results": [
    {
      "chatId": 123,
      "classification": "on_me",
      "urgency": "high",
      "reason": "Contact asked for an update and has not received one yet.",
      "suggestedAction": "Reply with a status update and expected timing.",
      "confidence": 0.87,
      "supportingMessageIds": [111, 112]
    }
  ]
}

Valid classification values: "on_me", "on_them", "quiet", "need_more"
Valid urgency values: "high", "medium", "low"
""".strip()


@dataclass
class Scenario:
    name: str
    model: str
    candidate_limit: int
    batch_size: int
    service_tier: Optional[str] = None
    prompt_cache_key: Optional[str] = None
    payload_style: str = "raw"


def canonical_model(model: str) -> str:
    lowered = model.strip().lower()
    if lowered.startswith("gpt-5-mini"):
        return "gpt-5-mini"
    if lowered.startswith("gpt-5.4-mini"):
        return "gpt-5.4-mini"
    if lowered.startswith("gpt-5.4-nano"):
        return "gpt-5.4-nano"
    if lowered.startswith("gpt-4o-mini"):
        return "gpt-4o-mini"
    if lowered.startswith("gpt-4.1-mini"):
        return "gpt-4.1-mini"
    return model


def pick_compact_snippets(candidate: dict[str, Any]) -> list[dict[str, Any]]:
    messages = candidate.get("messages", [])
    if not messages:
        return []
    latest = messages[-1]
    inbound = next((m for m in reversed(messages) if m.get("senderFirstName") != "[ME]"), None)
    outbound = next((m for m in reversed(messages) if m.get("senderFirstName") == "[ME]"), None)
    picked = []
    seen = set()
    for item in [latest, inbound, outbound]:
        if item and item["messageId"] not in seen:
            seen.add(item["messageId"])
            picked.append(item)
    return picked


def build_raw_user_message(query: str, scope: str, candidates: list[dict[str, Any]]) -> str:
    lines = [f'User query: "{query}"', f"Scope: {scope}", "Return one result for every candidate chatId.", "", "Candidate chats:"]
    for candidate in candidates:
        lines.append("")
        lines.append("---")
        lines.append(f"chatId: {candidate['chatId']}")
        lines.append(f"chatName: {candidate['chatName']}")
        lines.append(f"chatType: {candidate['chatType']}")
        lines.append(f"unreadCount: {candidate['unreadCount']}")
        if candidate.get("memberCount") is not None:
            lines.append(f"memberCount: {candidate['memberCount']}")
        lines.append(f"localSignal: {candidate['localSignal']}")
        lines.append("Messages (oldest first):")
        for message in candidate.get("messages", []):
            lines.append(
                f"[messageId: {message['messageId']}] "
                f"[{message['relativeTimestamp']}] "
                f"{message['senderFirstName']}: {message['text']}"
            )
    return "\n".join(lines)


def build_compact_user_message(query: str, scope: str, candidates: list[dict[str, Any]]) -> str:
    lines = [
        f'User query: "{query}"',
        f"Scope: {scope}",
        "Return one result for every candidate chatId.",
        "Each candidate includes a compact local digest and only the most relevant recent snippets.",
        "",
        "Candidate chats:",
    ]
    for candidate in candidates:
        lines.append("")
        lines.append("---")
        lines.append(f"chatId: {candidate['chatId']}")
        lines.append(f"chatName: {candidate['chatName']}")
        lines.append(f"chatType: {candidate['chatType']}")
        lines.append(f"unreadCount: {candidate['unreadCount']}")
        if candidate.get("memberCount") is not None:
            lines.append(f"memberCount: {candidate['memberCount']}")
        lines.append(f"localSignal: {candidate['localSignal']}")
        lines.append(f"pipelineHint: {candidate.get('pipelineHint', 'uncategorized')}")
        lines.append(f"replyOwed: {candidate.get('replyOwed')}")
        lines.append(f"strictReplySignal: {candidate.get('strictReplySignal')}")
        lines.append(f"effectiveGroupReplySignal: {candidate.get('effectiveGroupReplySignal')}")
        lines.append("Key snippets:")
        for message in pick_compact_snippets(candidate):
            lines.append(
                f"[messageId: {message['messageId']}] "
                f"[{message['relativeTimestamp']}] "
                f"{message['senderFirstName']}: {message['text']}"
            )
    return "\n".join(lines)


def build_user_message(query: str, scope: str, candidates: list[dict[str, Any]], payload_style: str = "raw") -> str:
    if payload_style == "compact":
        return build_compact_user_message(query, scope, candidates)
    return build_raw_user_message(query, scope, candidates)


def response_format_for_candidates(candidates: list[dict[str, Any]]) -> dict[str, Any]:
    candidate_ids = [candidate["chatId"] for candidate in candidates]
    return {
        "type": "json_schema",
        "json_schema": {
            "name": "reply_queue_triage",
            "strict": True,
            "schema": {
                "type": "object",
                "properties": {
                    "results": {
                        "type": "array",
                        "minItems": len(candidates),
                        "maxItems": len(candidates),
                        "items": {
                            "type": "object",
                            "properties": {
                                "chatId": {"type": "integer", "enum": candidate_ids},
                                "classification": {"type": "string", "enum": ["on_me", "on_them", "quiet", "need_more"]},
                                "urgency": {"type": "string", "enum": ["high", "medium", "low"]},
                                "reason": {"type": "string"},
                                "suggestedAction": {"type": "string"},
                                "confidence": {"type": "number", "minimum": 0, "maximum": 1},
                                "supportingMessageIds": {
                                    "type": "array",
                                    "items": {"type": "integer"},
                                },
                            },
                            "required": [
                                "chatId",
                                "classification",
                                "urgency",
                                "reason",
                                "suggestedAction",
                                "confidence",
                                "supportingMessageIds",
                            ],
                            "additionalProperties": False,
                        },
                    }
                },
                "required": ["results"],
                "additionalProperties": False,
            },
        },
    }


def parse_content(choice_message: dict[str, Any]) -> str:
    content = choice_message.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts: list[str] = []
        for part in content:
            if isinstance(part, dict):
                text = part.get("text")
                if isinstance(text, str):
                    parts.append(text)
                elif isinstance(text, dict) and isinstance(text.get("value"), str):
                    parts.append(text["value"])
        return "".join(parts)
    raise ValueError("Could not extract assistant content")


def extract_usage(payload: dict[str, Any]) -> dict[str, int]:
    usage = payload.get("usage", {}) or {}
    prompt_tokens = int(usage.get("prompt_tokens", 0) or 0)
    completion_tokens = int(usage.get("completion_tokens", 0) or 0)
    prompt_details = usage.get("prompt_tokens_details", {}) or {}
    cached_tokens = int(prompt_details.get("cached_tokens", 0) or 0)
    return {
        "prompt_tokens": prompt_tokens,
        "cached_prompt_tokens": cached_tokens,
        "uncached_prompt_tokens": max(0, prompt_tokens - cached_tokens),
        "completion_tokens": completion_tokens,
    }


def estimate_cost(model: str, tier: str, usage: dict[str, int]) -> Optional[float]:
    family = canonical_model(model)
    rates = PRICING.get(family, {}).get(tier)
    if not rates:
        return None
    return (
        usage["uncached_prompt_tokens"] / 1_000_000 * rates["input"]
        + usage["cached_prompt_tokens"] / 1_000_000 * rates["cached_input"]
        + usage["completion_tokens"] / 1_000_000 * rates["output"]
    )


def call_openai(
    api_key: str,
    model: str,
    query: str,
    scope: str,
    candidates: list[dict[str, Any]],
    payload_style: str = "raw",
    service_tier: Optional[str] = None,
    prompt_cache_key: Optional[str] = None,
) -> dict[str, Any]:
    body: dict[str, Any] = {
        "model": model,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": build_user_message(query, scope, candidates, payload_style)},
        ],
        "response_format": response_format_for_candidates(candidates),
    }
    if service_tier:
        body["service_tier"] = service_tier
    if prompt_cache_key:
        body["prompt_cache_key"] = prompt_cache_key

    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        "https://api.openai.com/v1/chat/completions",
        data=data,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
        },
    )

    started = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=180) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="ignore")
        raise RuntimeError(f"OpenAI HTTP {error.code}: {body}") from error
    elapsed_ms = int((time.perf_counter() - started) * 1000)

    content = parse_content(payload["choices"][0]["message"])
    parsed = json.loads(content)
    results = parsed["results"]
    expected_ids = {candidate["chatId"] for candidate in candidates}
    returned_ids = {item["chatId"] for item in results}
    if len(results) != len(candidates) or returned_ids != expected_ids:
        raise RuntimeError(
            f"Cardinality mismatch: expected {len(candidates)} / {sorted(expected_ids)} but got {len(results)} / {sorted(returned_ids)}"
        )

    usage = extract_usage(payload)
    return {
        "elapsed_ms": elapsed_ms,
        "usage": usage,
        "result_count": len(results),
        "on_me_count": sum(1 for item in results if item["classification"] == "on_me"),
        "need_more_count": sum(1 for item in results if item["classification"] == "need_more"),
        "raw_response": payload,
        "parsed_results": results,
    }


def load_api_key(path: Path) -> str:
    if os.environ.get("OPENAI_API_KEY"):
        return os.environ["OPENAI_API_KEY"]
    return path.read_text().strip()


def default_scenarios(default_model: str) -> list[Scenario]:
    return [
        Scenario(name="current_like", model=default_model, candidate_limit=24, batch_size=24),
        Scenario(name="top12_single_batch", model=default_model, candidate_limit=12, batch_size=12),
        Scenario(name="top8_single_batch", model=default_model, candidate_limit=8, batch_size=8),
        Scenario(name="gpt4.1mini_top12", model="gpt-4.1-mini", candidate_limit=12, batch_size=12),
        Scenario(name="gpt4.1mini_top24", model="gpt-4.1-mini", candidate_limit=24, batch_size=24),
    ]


def run_scenario(api_key: str, snapshot: dict[str, Any], scenario: Scenario) -> dict[str, Any]:
    candidates = snapshot["candidates"][: scenario.candidate_limit]
    batches = [
        candidates[index:index + scenario.batch_size]
        for index in range(0, len(candidates), scenario.batch_size)
    ]

    scenario_started = time.perf_counter()
    batch_results: list[dict[str, Any]] = []
    total_usage = {"prompt_tokens": 0, "cached_prompt_tokens": 0, "uncached_prompt_tokens": 0, "completion_tokens": 0}
    total_on_me = 0
    total_need_more = 0

    for batch_index, batch in enumerate(batches, start=1):
        result = call_openai(
            api_key=api_key,
            model=scenario.model,
            query=snapshot["query"],
            scope=snapshot["scope"],
            candidates=batch,
            payload_style=scenario.payload_style,
            service_tier=scenario.service_tier,
            prompt_cache_key=scenario.prompt_cache_key,
        )
        batch_results.append(
            {
                "batch_index": batch_index,
                "size": len(batch),
                "elapsed_ms": result["elapsed_ms"],
                "on_me_count": result["on_me_count"],
                "need_more_count": result["need_more_count"],
                "on_me_chat_ids": [item["chatId"] for item in result["parsed_results"] if item["classification"] == "on_me"],
                "usage": result["usage"],
            }
        )
        for key in total_usage:
            total_usage[key] += result["usage"][key]
        total_on_me += result["on_me_count"]
        total_need_more += result["need_more_count"]

    total_elapsed_ms = int((time.perf_counter() - scenario_started) * 1000)
    return {
        "name": scenario.name,
        "model": scenario.model,
        "service_tier": scenario.service_tier or "standard",
        "payload_style": scenario.payload_style,
        "candidate_limit": scenario.candidate_limit,
        "batch_size": scenario.batch_size,
        "batch_count": len(batches),
        "total_elapsed_ms": total_elapsed_ms,
        "total_usage": total_usage,
        "estimated_standard_cost_usd": estimate_cost(scenario.model, "standard", total_usage),
        "estimated_priority_cost_usd": estimate_cost(scenario.model, "priority", total_usage),
        "total_on_me_count": total_on_me,
        "total_need_more_count": total_need_more,
        "on_me_chat_ids": sorted({
            chat_id
            for batch in batch_results
            for chat_id in batch["on_me_chat_ids"]
        }),
        "batches": batch_results,
    }


def print_summary(results: list[dict[str, Any]]) -> None:
    print()
    print("Reply queue benchmark results")
    print("=" * 80)
    for result in results:
        print(
            f"{result['name']}: model={result['model']} tier={result['service_tier']} "
            f"payload={result['payload_style']} "
            f"candidates={result['candidate_limit']} batches={result['batch_count']} "
            f"elapsed={result['total_elapsed_ms']}ms on_me={result['total_on_me_count']} "
            f"need_more={result['total_need_more_count']} "
            f"std_cost=${(result['estimated_standard_cost_usd'] or 0):.5f} "
            f"priority_cost=${(result['estimated_priority_cost_usd'] or 0):.5f}"
        )
        for batch in result["batches"]:
            usage = batch["usage"]
            print(
                f"  batch {batch['batch_index']}: size={batch['size']} elapsed={batch['elapsed_ms']}ms "
                f"prompt={usage['prompt_tokens']} cached={usage['cached_prompt_tokens']} "
                f"completion={usage['completion_tokens']} on_me={batch['on_me_count']}"
            )


def main() -> int:
    parser = argparse.ArgumentParser(description="Benchmark reply queue AI triage directly against captured candidates.")
    parser.add_argument("--candidates", type=Path, default=DEFAULT_CANDIDATES_PATH)
    parser.add_argument("--api-key-file", type=Path, default=DEFAULT_API_KEY_PATH)
    parser.add_argument("--results-out", type=Path, default=DEFAULT_RESULTS_PATH)
    parser.add_argument("--scenario", action="append", help="Custom scenario in the form name:model:candidate_limit:batch_size[:tier[:payload_style]]")
    args = parser.parse_args()

    if not args.candidates.exists():
        print(f"Candidate snapshot not found: {args.candidates}", file=sys.stderr)
        return 1

    snapshot = json.loads(args.candidates.read_text())
    api_key = load_api_key(args.api_key_file)

    if args.scenario:
        scenarios = []
        for raw in args.scenario:
            parts = raw.split(":")
            if len(parts) not in {4, 5, 6}:
                raise SystemExit(f"Bad scenario '{raw}'. Expected name:model:candidate_limit:batch_size[:tier[:payload_style]]")
            scenarios.append(
                Scenario(
                    name=parts[0],
                    model=parts[1],
                    candidate_limit=int(parts[2]),
                    batch_size=int(parts[3]),
                    service_tier=parts[4] if len(parts) >= 5 else None,
                    payload_style=parts[5] if len(parts) == 6 else "raw",
                )
            )
    else:
        default_model = snapshot.get("providerModel") or "gpt-5-mini"
        scenarios = default_scenarios(default_model)

    results = []
    for scenario in scenarios:
        print(f"Running scenario: {scenario.name}", file=sys.stderr)
        results.append(run_scenario(api_key, snapshot, scenario))

    payload = {
        "capturedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "snapshotQuery": snapshot["query"],
        "snapshotScope": snapshot["scope"],
        "scenarioCount": len(results),
        "results": results,
    }
    args.results_out.parent.mkdir(parents=True, exist_ok=True)
    args.results_out.write_text(json.dumps(payload, indent=2, sort_keys=True))
    print_summary(results)
    print()
    print(f"Saved JSON: {args.results_out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
