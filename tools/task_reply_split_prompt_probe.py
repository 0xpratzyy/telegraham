#!/usr/bin/env python3
"""Probe prompt behavior for routing Telegram asks into reply queue vs tasks.

The probe uses synthetic messages only. It is meant to test prompt shape before
changing product code.
"""

import argparse
import json
import os
import sys
import textwrap
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional


APP_SUPPORT = Path.home() / "Library" / "Application Support" / "Pidgy"
OPENAI_KEY_PATH = APP_SUPPORT / "credentials" / "com.pidgy.aiApiKey.openai"


SYSTEM_PROMPT = """
You are a routing classifier for a Telegram deep-work dashboard.

Your job is to decide whether each candidate conversation should become:
- "reply_only": the user owes a chat reply, confirmation, answer, or quick clarification.
- "effort_task": the user is being asked to do non-trivial work outside the chat.
- "ignore": the ask is not directed to the user, is ambient chatter, is already closed, or ownership is too unclear.

Return exactly one result for every candidate caseId.

Important judgment rules:
- A result can be reply_only or effort_task only when the ask is directed to the user or strongly implied to be for the user.
- Do not rely only on @mentions or name tags. In small groups, infer implied ownership from context: the user's role, prior [ME] commitments, direct follow-up to the user's last message, or a chat/project where the user is clearly the owner.
- If the ask targets someone else, use ignore unless [ME] later accepts that work.
- If ownership is genuinely unclear, use ignore.
- reply_only means a message back is enough and the work is roughly under five minutes.
- effort_task means the user needs to prepare, review, fix, send an artifact, introduce people, schedule, pay, investigate, update a doc/config, or otherwise do work beyond a quick reply.
- A request to send or share a pitch deck, deck, doc, file, link, invoice, contract, screenshot, media, or another artifact is effort_task when the user owns it, even if he can also reply with a short note.
- If both a reply and outside work are needed, choose effort_task.
- Treat FYIs, status dumps, greetings, and closed loops as ignore.

Return JSON only:
{
  "results": [
    {
      "caseId": "dm_reply_only",
      "route": "reply_only",
      "directedness": "direct_to_me",
      "effortLevel": "quick_reply",
      "title": "Confirm Thursday timing",
      "suggestedAction": "Reply with whether Thursday works.",
      "reason": "Akhil asks the user for a quick confirmation.",
      "confidence": 0.94,
      "supportingMessageIds": [1001]
    }
  ]
}

Valid route values: "reply_only", "effort_task", "ignore"
Valid directedness values: "direct_to_me", "implied_to_me", "not_me", "unclear"
Valid effortLevel values: "none", "quick_reply", "non_trivial_work"
""".strip()


@dataclass(frozen=True)
class Case:
    case_id: str
    expected_route: str
    expected_directedness: str
    expected_title: str
    user_context: str
    chat: dict[str, Any]
    messages: list[dict[str, Any]]
    why_it_matters: str


CASES = [
    Case(
        case_id="dm_reply_only",
        expected_route="reply_only",
        expected_directedness="direct_to_me",
        expected_title="Confirm Thursday timing",
        user_context="You are Pratyush. This is a direct message.",
        chat={"chatId": 101, "chatTitle": "Akhil", "chatType": "private", "memberCount": 2},
        messages=[
            {"messageId": 1001, "sender": "Akhil", "text": "Can you confirm if Thursday works? quick yes/no is fine."}
        ],
        why_it_matters="This should stay in Reply Queue, not become a durable task.",
    ),
    Case(
        case_id="dm_effort_task",
        expected_route="effort_task",
        expected_directedness="direct_to_me",
        expected_title="Review contract redlines",
        user_context="You are Pratyush. This is a direct message.",
        chat={"chatId": 102, "chatTitle": "Maaz", "chatType": "private", "memberCount": 2},
        messages=[
            {"messageId": 1101, "sender": "Maaz", "text": "Can you review the new contract redlines and send comments by EOD?"}
        ],
        why_it_matters="A DM ask can be a task when it requires work outside chat.",
    ),
    Case(
        case_id="small_group_implied_owner_task",
        expected_route="effort_task",
        expected_directedness="implied_to_me",
        expected_title="Share latest pricing deck",
        user_context=(
            "You are Pratyush. In this 4-person First Dollar group, you own the pricing deck "
            "and partner-facing materials."
        ),
        chat={"chatId": 201, "chatTitle": "First Dollar core", "chatType": "group", "memberCount": 4},
        messages=[
            {"messageId": 2001, "sender": "[ME]", "text": "I'll keep the pricing deck updated today."},
            {"messageId": 2002, "sender": "Disha", "text": "Need the latest pricing deck before the partner call. Can we get it in here before 5?"},
        ],
        why_it_matters="No name or @tag, but context makes this user's task.",
    ),
    Case(
        case_id="small_group_implied_owner_reply",
        expected_route="reply_only",
        expected_directedness="implied_to_me",
        expected_title="Answer annual billing question",
        user_context=(
            "You are Pratyush. In this 3-person First Dollar group, you answer partnership "
            "and pricing questions."
        ),
        chat={"chatId": 202, "chatTitle": "First Dollar pricing", "chatType": "group", "memberCount": 3},
        messages=[
            {"messageId": 2101, "sender": "[ME]", "text": "I can answer partner pricing questions before the call."},
            {"messageId": 2102, "sender": "Akhil", "text": "Do we support annual billing here? Need quick yes/no before I speak to them."},
        ],
        why_it_matters="Small-group implied ownership can still be reply-only.",
    ),
    Case(
        case_id="small_group_ambient_unowned",
        expected_route="ignore",
        expected_directedness="not_me",
        expected_title="No route",
        user_context=(
            "You are Pratyush. This is a 4-person builder group. There is no evidence you own "
            "deployment, infra, or the staging environment."
        ),
        chat={"chatId": 203, "chatTitle": "Builder pod", "chatType": "group", "memberCount": 4},
        messages=[
            {"messageId": 2201, "sender": "Nina", "text": "Can someone check why staging deploy is failing?"},
            {"messageId": 2202, "sender": "Rahul", "text": "Might be the Vercel config again."},
        ],
        why_it_matters="Small group alone must not make every ambient ask mine.",
    ),
    Case(
        case_id="group_direct_reply_only",
        expected_route="reply_only",
        expected_directedness="direct_to_me",
        expected_title="Confirm revenue split",
        user_context="You are Pratyush. Your teammates sometimes address you by first name.",
        chat={"chatId": 301, "chatTitle": "Helix partnership", "chatType": "group", "memberCount": 8},
        messages=[
            {"messageId": 3001, "sender": "Akhil", "text": "Pratyush, are we okay with 70/30 on this split?"}
        ],
        why_it_matters="A direct ask can be just a reply.",
    ),
    Case(
        case_id="group_direct_effort_task",
        expected_route="effort_task",
        expected_directedness="direct_to_me",
        expected_title="Fix Vercel domain config",
        user_context="You are Pratyush. Your teammates sometimes address you by first name.",
        chat={"chatId": 302, "chatTitle": "Launch room", "chatType": "group", "memberCount": 7},
        messages=[
            {"messageId": 3101, "sender": "Priya", "text": "Pratyush, can you fix the Vercel domain config before launch?"}
        ],
        why_it_matters="A direct ask can be a task when it needs effort.",
    ),
    Case(
        case_id="group_other_person",
        expected_route="ignore",
        expected_directedness="not_me",
        expected_title="No route",
        user_context="You are Pratyush. Rahul is another teammate in the chat.",
        chat={"chatId": 303, "chatTitle": "Bento Alpha", "chatType": "group", "memberCount": 9},
        messages=[
            {"messageId": 3201, "sender": "Akhil", "text": "@rahul can you send the final deck here?"}
        ],
        why_it_matters="Direct-to-someone-else should not become my task or reply.",
    ),
]


def build_user_message(cases: list[Case]) -> str:
    lines = [
        "Classify these synthetic Telegram cases.",
        "The current user is Pratyush, also known as @pratyush.",
        "Messages are oldest first. [ME] means Pratyush sent that message.",
        "",
        "Cases:",
    ]
    for case in cases:
        lines.append("")
        lines.append("---")
        lines.append(f"caseId: {case.case_id}")
        lines.append(f"userContext: {case.user_context}")
        lines.append(f"chatId: {case.chat['chatId']}")
        lines.append(f"chatTitle: {case.chat['chatTitle']}")
        lines.append(f"chatType: {case.chat['chatType']}")
        lines.append(f"memberCount: {case.chat['memberCount']}")
        lines.append("messages:")
        for message in case.messages:
            lines.append(f"[messageId: {message['messageId']}] {message['sender']}: {message['text']}")
    return "\n".join(lines)


def expected_results(cases: list[Case]) -> dict[str, dict[str, Any]]:
    return {
        case.case_id: {
            "caseId": case.case_id,
            "route": case.expected_route,
            "directedness": case.expected_directedness,
            "title": None if case.expected_route == "ignore" else case.expected_title,
            "reason": case.why_it_matters,
            "confidence": 1.0,
        }
        for case in cases
    }


def load_api_key(use_saved_key: bool) -> Optional[str]:
    env_key = os.environ.get("OPENAI_API_KEY", "").strip()
    if env_key:
        return env_key
    if use_saved_key and OPENAI_KEY_PATH.exists():
        return OPENAI_KEY_PATH.read_text(encoding="utf-8").strip()
    return None


def call_openai(model: str, api_key: str, user_message: str) -> dict[str, Any]:
    body = {
        "model": model,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": user_message},
        ],
        "temperature": 0,
        "response_format": {"type": "json_object"},
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
    try:
        with urllib.request.urlopen(req, timeout=60) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"OpenAI HTTP {exc.code}: {detail}") from exc

    content = payload["choices"][0]["message"]["content"]
    parsed = json.loads(content)
    parsed["_usage"] = payload.get("usage", {})
    parsed["_model"] = payload.get("model", model)
    return parsed


def normalize_results(payload: dict[str, Any]) -> dict[str, dict[str, Any]]:
    by_case: dict[str, dict[str, Any]] = {}
    for item in payload.get("results", []):
        case_id = str(item.get("caseId", ""))
        if case_id:
            by_case[case_id] = item
    return by_case


def render_table(cases: list[Case], actual: dict[str, dict[str, Any]], source: str) -> str:
    rows = []
    passed = 0
    for case in cases:
        item = actual.get(case.case_id, {})
        route = item.get("route", "missing")
        directedness = item.get("directedness", "missing")
        ok = route == case.expected_route and directedness == case.expected_directedness
        if ok:
            passed += 1
        rows.append(
            [
                "PASS" if ok else "FAIL",
                case.case_id,
                case.expected_route,
                str(route),
                case.expected_directedness,
                str(directedness),
                str(item.get("reason", ""))[:86],
            ]
        )

    headers = ["ok", "case", "expected", source, "expected_owner", "owner", "reason"]
    widths = [len(header) for header in headers]
    for row in rows:
        for idx, value in enumerate(row):
            widths[idx] = max(widths[idx], len(value))

    def fmt(row: list[str]) -> str:
        return "  ".join(value.ljust(widths[idx]) for idx, value in enumerate(row))

    lines = [fmt(headers), fmt(["-" * width for width in widths])]
    lines.extend(fmt(row) for row in rows)
    lines.append("")
    lines.append(f"score: {passed}/{len(cases)}")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true", help="Call OpenAI on synthetic fixtures.")
    parser.add_argument("--use-saved-key", action="store_true", help="Allow reading the saved Pidgy OpenAI key.")
    parser.add_argument("--model", default="gpt-4.1-mini", help="OpenAI chat/completions model.")
    parser.add_argument("--show-prompt", action="store_true", help="Print the proposed system and user prompt.")
    args = parser.parse_args()

    user_message = build_user_message(CASES)
    if args.show_prompt:
        print("=== system prompt ===")
        print(SYSTEM_PROMPT)
        print("\n=== user prompt ===")
        print(user_message)
        print("")

    print("=== expected routing matrix ===")
    print(render_table(CASES, expected_results(CASES), "expected"))

    if not args.live:
        print(
            textwrap.dedent(
                """
                live AI: skipped
                Run with --live to ask the model to classify the same synthetic cases.
                The live mode sends only these synthetic fixtures, never Telegram history.
                """
            ).strip()
        )
        return 0

    api_key = load_api_key(args.use_saved_key)
    if not api_key:
        print("live AI: skipped, no OPENAI_API_KEY and --use-saved-key was not provided", file=sys.stderr)
        return 2

    print(f"\n=== live AI result ({args.model}) ===")
    payload = call_openai(args.model, api_key, user_message)
    actual = normalize_results(payload)
    print(render_table(CASES, actual, "actual"))
    usage = payload.get("_usage", {})
    print(f"model: {payload.get('_model', args.model)}")
    if usage:
        print(
            "tokens: "
            f"prompt={usage.get('prompt_tokens', 0)} "
            f"completion={usage.get('completion_tokens', 0)} "
            f"total={usage.get('total_tokens', 0)}"
        )
    print("\nraw:")
    print(json.dumps({k: v for k, v in payload.items() if not k.startswith("_")}, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
