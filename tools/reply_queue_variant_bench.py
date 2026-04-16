#!/usr/bin/env python3
import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional


APP_SUPPORT = Path.home() / "Library" / "Application Support" / "Pidgy"
DEFAULT_SNAPSHOT_PATH = APP_SUPPORT / "debug" / "reply_queue_candidate_snapshots" / "mixed_recent_48.json"
DEFAULT_OUT_DIR = APP_SUPPORT / "debug" / "group_precision_bench"
DEFAULT_API_KEY_PATH = APP_SUPPORT / "credentials" / "com.pidgy.aiApiKey"
LEGACY_API_KEY_PATH = APP_SUPPORT / "credentials" / "com.tgsearch.aiApiKey"
PROVIDER_SCOPED_API_KEY_PATHS = [
    APP_SUPPORT / "credentials" / "com.pidgy.aiApiKey.openai",
    APP_SUPPORT / "credentials" / "com.pidgy.aiApiKey.claude",
]


PRICING = {
    "gpt-5.4-mini": {
        "standard": {"input": 0.75, "cached_input": 0.075, "output": 4.50},
        "priority": {"input": 1.50, "cached_input": 0.15, "output": 9.00},
    }
}


BASE_SYSTEM_PROMPT = """
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


TIERED_BASE_SYSTEM_PROMPT = """
You triage Telegram chats for a BD/community operator.
Your job is to decide whether the user currently owes a reply in each candidate chat.

You will receive many candidate chats at once. Return exactly one result for every candidate chatId.

Classification rules:
- "on_me": the user clearly owes a reply or follow-up now.
- "worth_checking": there is a real open loop worth surfacing in a secondary bucket, but it is not strong or fresh enough to claim as a primary reply-now item.
- "on_them": the other side owns the next step, or the user already replied and is waiting.
- "quiet": no active obligation right now.
- "need_more": only use when the provided context is genuinely insufficient to tell.

Key judgment rules:
- Use "worth_checking" for stale or diluted open loops: someone did ask the user something, but later discussion, age, or ambiguous ownership makes it too weak for "on_me".
- In groups, prefer "worth_checking" over "on_me" when an older request is still somewhat relevant but there is no fresh direct ask on the user now.
- Treat acknowledgements, reactions, celebrations, and thread-closing chatter as "quiet" unless a new ask appears.
- If the other side clearly owns the next step, use "on_them", not "worth_checking".
- Use supportingMessageIds to point at the messages that justify the decision.
- suggestedAction should be short and practical.

Return exactly one JSON object:
{
  "results": [
    {
      "chatId": 123,
      "classification": "worth_checking",
      "urgency": "medium",
      "reason": "There was an earlier request for your input, but it is no longer fresh enough to count as reply-now.",
      "suggestedAction": "Review the thread and decide if a follow-up is still useful.",
      "confidence": 0.74,
      "supportingMessageIds": [111, 112]
    }
  ]
}

Valid classification values: "on_me", "worth_checking", "on_them", "quiet", "need_more"
Valid urgency values: "high", "medium", "low"
""".strip()


STRICT_GROUPS_APPENDIX = """

Extra strictness for groups:
- For group chats, default to "quiet" unless ownership is clearly on the user.
- Strong evidence for "on_me" in groups usually requires at least one of:
  1. a direct ask clearly aimed at the user,
  2. a follow-up on something the user explicitly promised to do,
  3. a reply that clearly expects the user specifically, not the group.
- If a message mentions another named person or @handle, assume it is aimed at them, not the user, unless later context clearly hands the task to the user.
- Broad coordination, open-ended group chatter, social conversation, and "someone should..." style messages should usually be "quiet", not "on_me".
- If the user's last message already resolved or acknowledged the ask and later messages do not reopen it, do not keep the group as "on_me".
- When group ownership is ambiguous, prefer "quiet" over "on_me".
""".strip()


PROMPT_VARIANTS = {
    "baseline": BASE_SYSTEM_PROMPT,
    "strict_groups_v1": BASE_SYSTEM_PROMPT + "\n\n" + STRICT_GROUPS_APPENDIX,
    "strict_groups_v1_digest_v2": BASE_SYSTEM_PROMPT + "\n\n" + STRICT_GROUPS_APPENDIX,
    "field_aware_groups_v2_digest_v3": BASE_SYSTEM_PROMPT + "\n\n" + STRICT_GROUPS_APPENDIX + "\n\n" + """
Use the structured digest fields carefully:
- For group chats, treat `groupOwnershipHint` as the strongest ownership clue unless the snippets clearly contradict it.
- If `groupOwnershipHint` is one of:
  - `mentioned_other_handle`
  - `broadcast_group_question`
  - `closed_after_actionable`
  - `closed_no_actionable_ask`
  - `waiting_on_them`
  - `no_clear_actionable_ask`
  then do NOT return `on_me` unless the snippets clearly show a newer direct ask aimed at the user.
- A `latestActionableInboundMentionsHandles` value that is not `none` usually means the ask is aimed at someone else.
- A broadcast question to a whole group is usually `quiet`, not `on_me`.
- If someone else already said they are fixing it / on it / taking a look, prefer `quiet` or `on_them`.
- If `closureAfterLatestActionable` is true and no newer ask appears, prefer `quiet`.
- For private chats, do not apply these group-specific downgrades. Preserve strong private follow-up candidates.
""".strip(),
    "field_aware_groups_v3_digest_v4": BASE_SYSTEM_PROMPT + "\n\n" + STRICT_GROUPS_APPENDIX + "\n\n" + """
Use the structured digest fields carefully:
- Treat `groupOwnershipHint` as the main ownership signal for groups.
- Treat `weakLocalHeuristic` as noisy metadata only. It must not override direct ownership evidence.
- If `groupOwnershipHint` is `mentioned_other_handle`, `closed_after_actionable`, `closed_no_actionable_ask`, `waiting_on_them`, or `no_clear_actionable_ask`, do not return `on_me` unless the snippets clearly show a newer direct ask aimed at the user.
- If `latestActionableInboundMentionsHandles` is not `none`, assume the ask is aimed at those handles, not the user.
- If `broadcastStyleLatestActionable` is true and `directSecondPersonLatestActionable` is false, default to `quiet` for groups.
- If a later message says `thank you`, `got it`, `on it`, `fixing that right now`, or similar after the actionable ask, prefer `quiet` or `on_them`.
- For private chats, preserve strong local reply candidates; do not downgrade them just because the latest inbound is short or casual.
""".strip(),
    "field_aware_groups_v2_private_recall_v1_digest_v3": BASE_SYSTEM_PROMPT + "\n\n" + STRICT_GROUPS_APPENDIX + "\n\n" + """
Use the structured digest fields carefully:
- For group chats, treat `groupOwnershipHint` as the strongest ownership clue unless the snippets clearly contradict it.
- If `groupOwnershipHint` is one of:
  - `mentioned_other_handle`
  - `broadcast_group_question`
  - `closed_after_actionable`
  - `closed_no_actionable_ask`
  - `waiting_on_them`
  - `no_clear_actionable_ask`
  then do NOT return `on_me` unless the snippets clearly show a newer direct ask aimed at the user.
- If `latestActionableInboundMentionsHandles` is not `none`, assume the ask is aimed at those handles, not the user, even if the user previously said they would message them.
- A broadcast question to a whole group is usually `quiet`, not `on_me`.
- If someone else already said they are fixing it / on it / taking a look, prefer `quiet` or `on_them`.
- If `closureAfterLatestActionable` is true and no newer ask appears, prefer `quiet`.
- For private chats, be more permissive: a terse follow-up can still be `on_me` when the thread is open, especially around updates, feedback, checking something, trying something out, scheduling, or blocking time.
- For private chats, do not require a question mark. Short asks like `try it`, `check once`, `let me know`, `kindly block`, `share feedback`, or `update me` can still be actionable if later context does not close them.
""".strip(),
    "field_aware_groups_v3_private_recall_v1_digest_v4": BASE_SYSTEM_PROMPT + "\n\n" + STRICT_GROUPS_APPENDIX + "\n\n" + """
Use the structured digest fields carefully:
- Treat `groupOwnershipHint` as the main ownership signal for groups.
- Treat `weakLocalHeuristic` as noisy metadata only. It must not override direct ownership evidence.
- If `groupOwnershipHint` is `mentioned_other_handle`, `closed_after_actionable`, `closed_no_actionable_ask`, `waiting_on_them`, or `no_clear_actionable_ask`, do not return `on_me` unless the snippets clearly show a newer direct ask aimed at the user.
- If `latestActionableInboundMentionsHandles` is not `none`, assume the ask is aimed at those handles, not the user, even if the user previously said they would reach out.
- If `broadcastStyleLatestActionable` is true and `directSecondPersonLatestActionable` is false, default to `quiet` for groups.
- If a later message says `thank you`, `got it`, `on it`, `fixing that right now`, or similar after the actionable ask, prefer `quiet` or `on_them`.
- For private chats, preserve strong follow-up candidates. If `privateOwnershipHint` is `private_direct_follow_up`, lean toward `on_me` unless there is clear later closure.
- For private chats, `privateReplySignal` is a helpful positive signal, not proof. Use it to recover terse follow-ups, not to override clear closure.
""".strip(),
    "field_aware_groups_v3_private_recall_v2_digest_v5": BASE_SYSTEM_PROMPT + "\n\n" + STRICT_GROUPS_APPENDIX + "\n\n" + """
Use the structured digest fields carefully:
- Treat `groupOwnershipHint` as the main ownership signal for groups.
- Treat `weakLocalHeuristic` as noisy metadata only. It must not override direct ownership evidence.
- If `groupOwnershipHint` is `mentioned_other_handle`, `closed_after_actionable`, `closed_no_actionable_ask`, `waiting_on_them`, or `no_clear_actionable_ask`, do not return `on_me` unless the snippets clearly show a newer direct ask aimed at the user.
- If `latestActionableInboundMentionsHandles` is not `none`, assume the ask is aimed at those handles, not the user, even if the user previously said they would message them.
- If `broadcastStyleLatestActionable` is true and `directSecondPersonLatestActionable` is false, default to `quiet` for groups.
- If a later message says `thank you`, `got it`, `on it`, `fixing that right now`, or similar after the actionable ask, prefer `quiet` or `on_them`.
- For private chats, use `privateOwnershipHint` as a strong cue. `private_direct_follow_up` usually means `on_me`, `private_waiting_on_them` usually means `on_them`, and `private_closed` usually means `quiet`.
- For private chats, `privateReplySignal` helps recover short follow-ups and operational asks even when the latest inbound is casual.
- Use the wider private snippet window to judge whether the conversation is still operationally open; do not require a formal question mark.
""".strip(),
    "field_aware_groups_v4_contextual_recovery_v1": BASE_SYSTEM_PROMPT + "\n\n" + STRICT_GROUPS_APPENDIX + "\n\n" + """
Use the structured digest fields carefully:
- Treat `groupOwnershipHint` as the main ownership signal for groups, but do not over-trust raw handle mentions by themselves.
- `explicitSecondPersonLatestActionable` is the only second-person field you should trust. Ignore bare `you` phrasing inside explanations or clarifications.
- If `latestActionableLooksExplanatory` is true in a group, default to `quiet` unless there is a separate explicit ask, direct mention, or a clearly unresolved user commitment.
- If `groupOwnershipHint` is `mentioned_other_handle` only because `ccStyleHandleMentions` is true, do not automatically reject `on_me`. Treat cc-style mentions as informational unless another field clearly shows the task moved elsewhere.
- If `earlierRequestForInputExists` is true and later snippets look like implementation notes, bug reports, or task lists from the same thread, the chat can still be `on_me` even when the latest actionable snippet is not phrased as a direct question.
- If someone else later says `got it`, `fixing that right now`, `on it`, `working on it`, or similar, prefer `quiet` or `on_them` even when there was an earlier request for your input.
- For private chats, use `privateOwnershipHint` as a strong cue. `private_direct_follow_up` usually means `on_me`, `private_waiting_on_them` usually means `on_them`, and `private_closed` usually means `quiet`.
- For private chats, `privateReplySignal` helps recover short follow-ups and operational asks even when the latest inbound is casual.
""".strip(),
    "field_aware_groups_v5_tiered_review_v1": TIERED_BASE_SYSTEM_PROMPT + "\n\n" + STRICT_GROUPS_APPENDIX + "\n\n" + """
Use the structured digest fields carefully:
- Treat `groupOwnershipHint` as the main ownership signal for groups.
- If `latestActionableLooksExplanatory` is true in a group, default to `quiet` unless another field shows a separate explicit ask.
- If `earlierRequestForInputExists` is true but the later context is more of a task dump, status list, or cc-style update than a fresh direct ask, prefer `worth_checking` over `on_me`.
- If `groupOwnershipHint` is `mentioned_other_handle` only because `ccStyleHandleMentions` is true, that is weak negative evidence, not an automatic rejection.
- If a newer direct ask clearly lands on the user, use `on_me`, not `worth_checking`.
- If the loop is obviously stale, diffuse, or buried under later discussion but still plausibly relevant, use `worth_checking`.
- If someone else later says `got it`, `fixing that right now`, `on it`, `working on it`, or similar, prefer `quiet` or `on_them`, not `worth_checking`.
- For private chats, use `privateOwnershipHint` as a strong cue. Use `worth_checking` for older private follow-ups that still matter but are no longer strong enough for reply-now.
""".strip(),
    "field_aware_groups_v6_tiered_review_v2": TIERED_BASE_SYSTEM_PROMPT + "\n\n" + STRICT_GROUPS_APPENDIX + "\n\n" + """
Use the structured digest fields carefully:
- Treat `groupOwnershipHint` as the main ownership signal for groups.
- `worth_checking` is a narrow bucket. In groups, use it only when there was a specific earlier ask or request for the user and that loop still looks unresolved, but the evidence is too stale or diluted for `on_me`.
- If `groupOwnershipHint` is `possible_user_owned_group_follow_up` by itself, that is not enough for `worth_checking`. You still need a concrete earlier ask, follow-up, or commitment that plausibly lands on the user.
- If `latestActionableLooksExplanatory` is true in a group, default to `quiet` unless another field shows a separate explicit ask.
- If `earlierRequestForInputExists` is true and the later context is still the same implementation or review thread, but there is no fresh direct ask, prefer `worth_checking`, not `on_me`.
- If the only evidence is an older request for input plus a later task dump, checklist, or cc-style update, keep it at `worth_checking` unless a newer explicit ask clearly lands on the user.
- If `earlierRequestForInputExists` is true but a later message shows someone else already acted or took ownership, prefer `quiet` or `on_them`, not `worth_checking`.
- If `groupOwnershipHint` is `mentioned_other_handle` only because `ccStyleHandleMentions` is true, that is weak negative evidence, not an automatic rejection.
- Treat recurring accountability groups, habit trackers, weekly scoreboards, check-in ledgers, and self-reported task lists as `quiet` unless there is a fresh direct ask aimed at the user.
- If `latestClosureText` or later snippets say `already added`, `done`, `done for the week`, `thank you`, `got it`, `on it`, `working on it`, `fixing that right now`, or similar, prefer `quiet` or `on_them`, not `worth_checking`.
- If a newer direct ask clearly lands on the user, use `on_me`, not `worth_checking`.
- For private chats, treat `private_waiting_on_them` as `on_them` and `private_closed` as `quiet` unless the other side clearly reopens the loop afterward.
- If the user's later private reply redirects the person to another owner or says someone else should handle it, prefer `on_them` or `quiet`, not `on_me`, unless there is a newer reopen after that redirect.
- For private chats, use `worth_checking` only for older private follow-ups that still matter but are no longer strong enough for reply-now.
""".strip(),
}


@dataclass(frozen=True)
class VariantRun:
    name: str
    prompt_variant: str
    payload_variant: str


def make_variant_name(prompt_variant: str, payload_variant: str) -> str:
    return f"{prompt_variant}_{payload_variant}_4x12"


BASE_VARIANT_TUPLES = [
    ("baseline", "compact_v1"),
    ("strict_groups_v1", "compact_v1"),
    ("strict_groups_v1_digest_v2", "digest_v2"),
    ("field_aware_groups_v2_digest_v3", "digest_v3"),
    ("field_aware_groups_v3_digest_v4", "digest_v4"),
    ("field_aware_groups_v2_private_recall_v1_digest_v3", "digest_v3"),
    ("field_aware_groups_v3_private_recall_v1_digest_v4", "digest_v4"),
    ("field_aware_groups_v3_private_recall_v2_digest_v5", "digest_v5"),
    ("field_aware_groups_v3_private_recall_v2_digest_v5", "digest_v6"),
    ("field_aware_groups_v4_contextual_recovery_v1", "digest_v6"),
    ("field_aware_groups_v5_tiered_review_v1", "digest_v6"),
    ("field_aware_groups_v6_tiered_review_v2", "digest_v6"),
]

ROBUST_MATRIX_TUPLES = [
    ("field_aware_groups_v2_digest_v3", "digest_v4"),
    ("field_aware_groups_v2_digest_v3", "digest_v5"),
    ("field_aware_groups_v3_digest_v4", "digest_v3"),
    ("field_aware_groups_v3_digest_v4", "digest_v5"),
    ("field_aware_groups_v2_private_recall_v1_digest_v3", "digest_v4"),
    ("field_aware_groups_v2_private_recall_v1_digest_v3", "digest_v5"),
    ("field_aware_groups_v3_private_recall_v1_digest_v4", "digest_v3"),
    ("field_aware_groups_v3_private_recall_v1_digest_v4", "digest_v5"),
    ("field_aware_groups_v3_private_recall_v2_digest_v5", "digest_v3"),
    ("field_aware_groups_v3_private_recall_v2_digest_v5", "digest_v4"),
]


def build_variant_runs() -> list[VariantRun]:
    seen: set[str] = set()
    runs: list[VariantRun] = []
    for prompt_variant, payload_variant in BASE_VARIANT_TUPLES + ROBUST_MATRIX_TUPLES:
        name = make_variant_name(prompt_variant, payload_variant)
        if name in seen:
            continue
        seen.add(name)
        runs.append(
            VariantRun(
                name=name,
                prompt_variant=prompt_variant,
                payload_variant=payload_variant,
            )
        )
    return runs


VARIANT_RUNS = build_variant_runs()

VARIANT_PACKS = {
    "core": [
        make_variant_name("baseline", "compact_v1"),
        make_variant_name("strict_groups_v1_digest_v2", "digest_v2"),
        make_variant_name("field_aware_groups_v2_digest_v3", "digest_v3"),
        make_variant_name("field_aware_groups_v3_digest_v4", "digest_v4"),
        make_variant_name("field_aware_groups_v3_private_recall_v2_digest_v5", "digest_v5"),
    ],
    "robust_v1": [
        make_variant_name(prompt_variant, payload_variant)
        for prompt_variant, payload_variant in BASE_VARIANT_TUPLES + ROBUST_MATRIX_TUPLES
    ],
    "shipping_candidates_v1": [
        make_variant_name("field_aware_groups_v2_digest_v3", "digest_v3"),
        make_variant_name("field_aware_groups_v2_private_recall_v1_digest_v3", "digest_v3"),
        make_variant_name("field_aware_groups_v3_private_recall_v2_digest_v5", "digest_v5"),
        make_variant_name("field_aware_groups_v2_digest_v3", "digest_v5"),
        make_variant_name("field_aware_groups_v3_digest_v4", "digest_v5"),
    ],
}


def normalize(text: str) -> str:
    return re.sub(r"\s+", " ", text.strip().lower())


def looks_actionable(text: str) -> bool:
    compact = re.sub(r"https?://\S+", " ", normalize(text))
    if not compact:
        return False
    if "?" in compact:
        return True
    signals = [
        "please", "pls", "can you", "could you", "let me know", "share", "send",
        "update", "review", "check", "approve", "confirm", "eta", "join", "when",
        "what", "how", "where", "reply", "follow up", "follow-up", "look into",
        "take a look", "help", "thoughts", "status",
    ]
    return any(signal in compact for signal in signals)


def looks_group_task_dump_follow_up(text: str) -> bool:
    compact = normalize(text)
    if not compact:
        return False
    task_signals = [
        "need to", "needs to", "changes", "fixes", "todo", "to do",
        "pending", "remaining", "review comments", "figma", "feedback",
    ]
    ownership_signals = [
        looks_cc_style_mentions(text),
        "input" in compact,
        "feedback" in compact,
        "review" in compact,
    ]
    return any(signal in compact for signal in task_signals) and any(ownership_signals)


def is_digest_actionable_inbound(message: dict[str, Any], chat_type: str) -> bool:
    if message.get("senderFirstName") == "[ME]":
        return False
    text = message.get("text", "")
    if looks_actionable(text):
        return True
    if chat_type == "group" and looks_group_task_dump_follow_up(text):
        return True
    return False


def looks_like_closure(text: str, from_me: bool) -> bool:
    compact = normalize(text)
    if not compact:
        return False
    closure_signals = [
        "done", "thanks", "thank you", "got it", "noted", "sounds good",
        "perfect", "resolved", "on it", "will do", "will share", "will send",
        "already added", "added it", "handled", "taken care of",
    ]
    if from_me:
        return any(compact == signal or signal in compact for signal in closure_signals)
    passive_signals = ["works", "all good", "fine", "cool", "great", "awesome"]
    return any(compact == signal or signal in compact for signal in (closure_signals + passive_signals))


def looks_like_commitment_from_me(text: str) -> bool:
    compact = normalize(text)
    if not compact:
        return False
    commitment_signals = [
        "i'll", "i will", "on it", "will do", "will share", "will send", "will check",
        "let me", "bhejta", "check karta", "i can", "will reply", "will update",
    ]
    return any(signal in compact for signal in commitment_signals)


def inbound_message_implies_contact_owns_next_step(text: str) -> bool:
    compact = normalize(text)
    if not compact:
        return False
    exact_signals = {
        "on it", "will do", "i will", "i ll", "working on it",
        "let me do it", "let me check", "will share", "will send",
        "done", "completed", "fixing that right now", "already added", "added it",
    }
    if compact in exact_signals:
        return True
    phrase_signals = [
        "on it", "will do", "i will", "i ll", "working on",
        "let me", "will share", "will send", "sending", "share soon",
        "taking a look", "take a look", "fixing that", "i got this",
        "already added", "added it", "handled", "taken care of",
    ]
    return any(signal in compact for signal in phrase_signals)


def looks_broadcast_group_ask(text: str) -> bool:
    compact = normalize(text)
    if not compact:
        return False
    broadcast_signals = [
        "hello guys", "hey guys", "guys", "anyone", "someone", "everyone",
        "folks", "team", "is there any opportunity", "can anyone", "who can",
        "who wants", "does anyone", "any dev", "any designer",
    ]
    return any(signal in compact for signal in broadcast_signals)


def looks_direct_second_person_ask(text: str) -> bool:
    compact = normalize(text)
    if not compact:
        return False
    direct_signals = [
        "can you", "could you", "would you", "will you", "please", "let me know",
        "do you", "are you", "you should", "you need to", "kindly",
    ]
    return any(signal in compact for signal in direct_signals)


def looks_request_for_input(text: str) -> bool:
    compact = normalize(text)
    if not compact:
        return False
    signals = [
        "give more input", "gib more input", "need input", "your input",
        "share feedback", "feedback", "thoughts", "what do you think",
        "let me know", "check once", "review this", "take a look",
    ]
    return any(signal in compact for signal in signals)


def looks_explanatory_group_reply(text: str) -> bool:
    compact = normalize(text)
    if not compact:
        return False
    explanatory_starts = [
        "you mean", "it means", "its too", "it's too", "you can just",
        "you can", "basically", "i think", "this means", "even if you try",
    ]
    return any(compact.startswith(prefix) for prefix in explanatory_starts)


def looks_cc_style_mentions(text: str) -> bool:
    compact = normalize(text)
    if not compact or "@" not in compact:
        return False
    return bool(re.search(r"\bcc\b\s+(@\w+[\s,]*)+$", compact))


def extract_handle_mentions(text: str) -> list[str]:
    return sorted(set(match.lower() for match in re.findall(r"@\w+", text or "")))


def compact_v1_user_message(query: str, scope: str, candidates: list[dict[str, Any]]) -> str:
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
            lines.append(format_message(message))

    return "\n".join(lines)


def digest_v2_user_message(query: str, scope: str, candidates: list[dict[str, Any]]) -> str:
    lines = [
        f'User query: "{query}"',
        f"Scope: {scope}",
        "Return one result for every candidate chatId.",
        "Each candidate includes a structured ownership digest plus the most relevant recent snippets.",
        "",
        "Candidate chats:",
    ]

    for candidate in candidates:
        messages = candidate.get("messages", [])
        latest = messages[-1] if messages else None
        latest_inbound = next((message for message in reversed(messages) if message.get("senderFirstName") != "[ME]"), None)
        latest_outbound = next((message for message in reversed(messages) if message.get("senderFirstName") == "[ME]"), None)
        latest_actionable_inbound = next(
            (
                message
                for message in reversed(messages)
                if is_digest_actionable_inbound(message, candidate.get("chatType", ""))
            ),
            None,
        )
        latest_closure = next(
            (
                message
                for message in reversed(messages)
                if looks_like_closure(message.get("text", ""), from_me=message.get("senderFirstName") == "[ME]")
            ),
            None,
        )
        latest_commitment = next(
            (
                message
                for message in reversed(messages)
                if message.get("senderFirstName") == "[ME]" and looks_like_commitment_from_me(message.get("text", ""))
            ),
            None,
        )
        last_actionable_mentions = extract_handle_mentions(latest_actionable_inbound.get("text", "") if latest_actionable_inbound else "")
        unresolved_after_me = bool(
            latest_actionable_inbound
            and (not latest_outbound or latest_actionable_inbound["messageId"] > latest_outbound["messageId"])
        )
        closure_after_actionable = bool(
            latest_actionable_inbound
            and latest_closure
            and latest_closure["messageId"] > latest_actionable_inbound["messageId"]
        )

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
        lines.append(f"latestSpeaker: {latest['senderFirstName'] if latest else 'none'}")
        lines.append(f"latestInboundSpeaker: {latest_inbound['senderFirstName'] if latest_inbound else 'none'}")
        lines.append(f"latestOutboundExists: {latest_outbound is not None}")
        lines.append(f"latestActionableInboundSpeaker: {latest_actionable_inbound['senderFirstName'] if latest_actionable_inbound else 'none'}")
        lines.append(f"latestActionableInboundMentionsHandles: {', '.join(last_actionable_mentions) if last_actionable_mentions else 'none'}")
        lines.append(f"latestCommitmentFromMe: {latest_commitment is not None}")
        lines.append(f"closureAfterLatestActionable: {closure_after_actionable}")
        lines.append(f"latestActionableStillAfterMyReply: {unresolved_after_me}")
        if latest_actionable_inbound:
            lines.append(f"latestActionableInboundText: {latest_actionable_inbound['text']}")
        if latest_commitment:
            lines.append(f"latestCommitmentText: {latest_commitment['text']}")
        if latest_closure:
            lines.append(f"latestClosureText: {latest_closure['text']}")
        lines.append("Key snippets:")
        for message in pick_digest_v2_snippets(candidate):
            lines.append(format_message(message))

    return "\n".join(lines)


def group_ownership_hint(
    candidate: dict[str, Any],
    latest_actionable_inbound: Optional[dict[str, Any]],
    latest_commitment: Optional[dict[str, Any]],
    latest_closure: Optional[dict[str, Any]],
    latest_outbound: Optional[dict[str, Any]],
    closure_after_actionable: bool,
    unresolved_after_me: bool,
    last_actionable_mentions: list[str],
) -> str:
    if candidate.get("chatType") != "group":
        return "direct_private_context"
    if latest_actionable_inbound is None:
        if latest_closure is not None:
            return "closed_no_actionable_ask"
        return "no_clear_actionable_ask"
    if last_actionable_mentions:
        return "mentioned_other_handle"
    actionable_text = latest_actionable_inbound.get("text", "")
    if looks_broadcast_group_ask(actionable_text) and not looks_direct_second_person_ask(actionable_text):
        return "broadcast_group_question"
    if closure_after_actionable:
        return "closed_after_actionable"
    if latest_closure and inbound_message_implies_contact_owns_next_step(latest_closure.get("text", "")):
        return "waiting_on_them"
    if latest_outbound and latest_outbound["messageId"] > latest_actionable_inbound["messageId"] and not unresolved_after_me:
        return "waiting_on_them"
    if latest_commitment and not unresolved_after_me:
        return "user_already_committed_no_reopen"
    if latest_commitment and unresolved_after_me:
        return "newer_follow_up_after_user_commitment"
    return "possible_user_owned_group_follow_up"


def latest_earlier_request_for_input(messages: list[dict[str, Any]], actionable_index: Optional[int]) -> Optional[dict[str, Any]]:
    if actionable_index is None:
        return None
    for index in range(actionable_index - 1, -1, -1):
        message = messages[index]
        if message.get("senderFirstName") == "[ME]":
            continue
        if looks_request_for_input(message.get("text", "")):
            return message
    return None


def pick_digest_v6_group_snippets(candidate: dict[str, Any]) -> list[dict[str, Any]]:
    messages = candidate.get("messages", [])
    if not messages:
        return []

    latest = messages[-1]
    latest_inbound = next((message for message in reversed(messages) if message.get("senderFirstName") != "[ME]"), None)
    latest_outbound = next((message for message in reversed(messages) if message.get("senderFirstName") == "[ME]"), None)
    actionable_index = next(
        (
            index
            for index in range(len(messages) - 1, -1, -1)
            if is_digest_actionable_inbound(messages[index], "group")
        ),
        None,
    )
    latest_actionable = messages[actionable_index] if actionable_index is not None else None
    earlier_request_for_input = latest_earlier_request_for_input(messages, actionable_index)
    context_before = []
    if actionable_index is not None:
        start = max(0, actionable_index - 3)
        context_before = messages[start:actionable_index]
    latest_commitment = next(
        (
            message
            for message in reversed(messages)
            if message.get("senderFirstName") == "[ME]" and looks_like_commitment_from_me(message.get("text", ""))
        ),
        None,
    )
    latest_closure = next(
        (
            message
            for message in reversed(messages)
            if looks_like_closure(message.get("text", ""), from_me=message.get("senderFirstName") == "[ME]")
            or inbound_message_implies_contact_owns_next_step(message.get("text", ""))
        ),
        None,
    )

    picked: list[dict[str, Any]] = []
    seen: set[int] = set()
    ordered = [latest, latest_actionable, earlier_request_for_input, *reversed(context_before), latest_commitment, latest_inbound, latest_outbound, latest_closure]
    for message in ordered:
        if message and message["messageId"] not in seen:
            seen.add(message["messageId"])
            picked.append(message)
    return picked


def digest_v3_user_message(query: str, scope: str, candidates: list[dict[str, Any]]) -> str:
    lines = [
        f'User query: "{query}"',
        f"Scope: {scope}",
        "Return one result for every candidate chatId.",
        "Each candidate includes a structured ownership digest and a minimal context window around the most relevant messages.",
        "",
        "Candidate chats:",
    ]

    for candidate in candidates:
        messages = candidate.get("messages", [])
        latest = messages[-1] if messages else None
        latest_inbound = next((message for message in reversed(messages) if message.get("senderFirstName") != "[ME]"), None)
        latest_outbound = next((message for message in reversed(messages) if message.get("senderFirstName") == "[ME]"), None)
        latest_actionable_inbound = next(
            (
                message
                for message in reversed(messages)
                if is_digest_actionable_inbound(message, candidate.get("chatType", ""))
            ),
            None,
        )
        latest_closure = next(
            (
                message
                for message in reversed(messages)
                if looks_like_closure(message.get("text", ""), from_me=message.get("senderFirstName") == "[ME]")
                or inbound_message_implies_contact_owns_next_step(message.get("text", ""))
            ),
            None,
        )
        latest_commitment = next(
            (
                message
                for message in reversed(messages)
                if message.get("senderFirstName") == "[ME]" and looks_like_commitment_from_me(message.get("text", ""))
            ),
            None,
        )
        last_actionable_mentions = extract_handle_mentions(latest_actionable_inbound.get("text", "") if latest_actionable_inbound else "")
        unresolved_after_me = bool(
            latest_actionable_inbound
            and (not latest_outbound or latest_actionable_inbound["messageId"] > latest_outbound["messageId"])
        )
        closure_after_actionable = bool(
            latest_actionable_inbound
            and latest_closure
            and latest_closure["messageId"] > latest_actionable_inbound["messageId"]
        )
        ownership_hint = group_ownership_hint(
            candidate,
            latest_actionable_inbound,
            latest_commitment,
            latest_closure,
            latest_outbound,
            closure_after_actionable,
            unresolved_after_me,
            last_actionable_mentions,
        )
        latest_actionable_text = latest_actionable_inbound.get("text", "") if latest_actionable_inbound else ""

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
        lines.append(f"groupOwnershipHint: {ownership_hint}")
        lines.append(f"latestSpeaker: {latest['senderFirstName'] if latest else 'none'}")
        lines.append(f"latestInboundSpeaker: {latest_inbound['senderFirstName'] if latest_inbound else 'none'}")
        lines.append(f"latestOutboundExists: {latest_outbound is not None}")
        lines.append(f"latestActionableInboundSpeaker: {latest_actionable_inbound['senderFirstName'] if latest_actionable_inbound else 'none'}")
        lines.append(f"latestActionableInboundMentionsHandles: {', '.join(last_actionable_mentions) if last_actionable_mentions else 'none'}")
        lines.append(f"broadcastStyleLatestActionable: {looks_broadcast_group_ask(latest_actionable_text)}")
        lines.append(f"directSecondPersonLatestActionable: {looks_direct_second_person_ask(latest_actionable_text)}")
        lines.append(f"latestCommitmentFromMe: {latest_commitment is not None}")
        lines.append(f"latestInboundOwnsNextStep: {bool(latest_closure and inbound_message_implies_contact_owns_next_step(latest_closure.get('text', '')))}")
        lines.append(f"closureAfterLatestActionable: {closure_after_actionable}")
        lines.append(f"latestActionableStillAfterMyReply: {unresolved_after_me}")
        if latest_actionable_inbound:
            lines.append(f"latestActionableInboundText: {latest_actionable_inbound['text']}")
        if latest_commitment:
            lines.append(f"latestCommitmentText: {latest_commitment['text']}")
        if latest_closure:
            lines.append(f"latestClosureText: {latest_closure['text']}")
        lines.append("Key snippets:")
        for message in pick_digest_v3_snippets(candidate):
            lines.append(format_message(message))

    return "\n".join(lines)


def digest_v4_user_message(query: str, scope: str, candidates: list[dict[str, Any]]) -> str:
    lines = [
        f'User query: "{query}"',
        f"Scope: {scope}",
        "Return one result for every candidate chatId.",
        "Each candidate includes a structured ownership digest. Local heuristic fields are intentionally weak hints, not proof.",
        "",
        "Candidate chats:",
    ]

    for candidate in candidates:
        messages = candidate.get("messages", [])
        latest = messages[-1] if messages else None
        latest_inbound = next((message for message in reversed(messages) if message.get("senderFirstName") != "[ME]"), None)
        latest_outbound = next((message for message in reversed(messages) if message.get("senderFirstName") == "[ME]"), None)
        latest_actionable_inbound = next(
            (
                message
                for message in reversed(messages)
                if is_digest_actionable_inbound(message, candidate.get("chatType", ""))
            ),
            None,
        )
        latest_closure = next(
            (
                message
                for message in reversed(messages)
                if looks_like_closure(message.get("text", ""), from_me=message.get("senderFirstName") == "[ME]")
                or inbound_message_implies_contact_owns_next_step(message.get("text", ""))
            ),
            None,
        )
        latest_commitment = next(
            (
                message
                for message in reversed(messages)
                if message.get("senderFirstName") == "[ME]" and looks_like_commitment_from_me(message.get("text", ""))
            ),
            None,
        )
        last_actionable_mentions = extract_handle_mentions(latest_actionable_inbound.get("text", "") if latest_actionable_inbound else "")
        unresolved_after_me = bool(
            latest_actionable_inbound
            and (not latest_outbound or latest_actionable_inbound["messageId"] > latest_outbound["messageId"])
        )
        closure_after_actionable = bool(
            latest_actionable_inbound
            and latest_closure
            and latest_closure["messageId"] > latest_actionable_inbound["messageId"]
        )
        ownership_hint = group_ownership_hint(
            candidate,
            latest_actionable_inbound,
            latest_commitment,
            latest_closure,
            latest_outbound,
            closure_after_actionable,
            unresolved_after_me,
            last_actionable_mentions,
        )
        latest_actionable_text = latest_actionable_inbound.get("text", "") if latest_actionable_inbound else ""

        lines.append("")
        lines.append("---")
        lines.append(f"chatId: {candidate['chatId']}")
        lines.append(f"chatName: {candidate['chatName']}")
        lines.append(f"chatType: {candidate['chatType']}")
        lines.append(f"unreadCount: {candidate['unreadCount']}")
        if candidate.get("memberCount") is not None:
            lines.append(f"memberCount: {candidate['memberCount']}")
        lines.append(
            "weakLocalHeuristic: "
            f"localSignal={candidate['localSignal']} "
            f"pipelineHint={candidate.get('pipelineHint', 'uncategorized')} "
            f"replyOwed={candidate.get('replyOwed')} "
            f"strictReplySignal={candidate.get('strictReplySignal')} "
            f"effectiveGroupReplySignal={candidate.get('effectiveGroupReplySignal')}"
        )
        lines.append(f"groupOwnershipHint: {ownership_hint}")
        lines.append(f"latestSpeaker: {latest['senderFirstName'] if latest else 'none'}")
        lines.append(f"latestInboundSpeaker: {latest_inbound['senderFirstName'] if latest_inbound else 'none'}")
        lines.append(f"latestOutboundExists: {latest_outbound is not None}")
        lines.append(f"latestActionableInboundSpeaker: {latest_actionable_inbound['senderFirstName'] if latest_actionable_inbound else 'none'}")
        lines.append(f"latestActionableInboundMentionsHandles: {', '.join(last_actionable_mentions) if last_actionable_mentions else 'none'}")
        lines.append(f"broadcastStyleLatestActionable: {looks_broadcast_group_ask(latest_actionable_text)}")
        lines.append(f"directSecondPersonLatestActionable: {looks_direct_second_person_ask(latest_actionable_text)}")
        lines.append(f"latestCommitmentFromMe: {latest_commitment is not None}")
        lines.append(f"latestInboundOwnsNextStep: {bool(latest_closure and inbound_message_implies_contact_owns_next_step(latest_closure.get('text', '')))}")
        lines.append(f"closureAfterLatestActionable: {closure_after_actionable}")
        lines.append(f"latestActionableStillAfterMyReply: {unresolved_after_me}")
        if latest_actionable_inbound:
            lines.append(f"latestActionableInboundText: {latest_actionable_inbound['text']}")
        if latest_commitment:
            lines.append(f"latestCommitmentText: {latest_commitment['text']}")
        if latest_closure:
            lines.append(f"latestClosureText: {latest_closure['text']}")
        lines.append("Key snippets:")
        for message in pick_digest_v3_snippets(candidate):
            lines.append(format_message(message))

    return "\n".join(lines)


def private_ownership_hint(
    latest_actionable_inbound: Optional[dict[str, Any]],
    latest_commitment: Optional[dict[str, Any]],
    latest_closure: Optional[dict[str, Any]],
    latest_outbound: Optional[dict[str, Any]],
    closure_after_actionable: bool,
    unresolved_after_me: bool,
) -> str:
    if latest_actionable_inbound is None:
        if latest_closure is not None:
            return "private_closed"
        return "private_unclear"
    if closure_after_actionable:
        return "private_closed"
    if latest_outbound and latest_outbound["messageId"] > latest_actionable_inbound["messageId"] and not unresolved_after_me:
        return "private_waiting_on_them"
    if latest_commitment and not unresolved_after_me:
        return "private_waiting_on_them"
    if unresolved_after_me or latest_commitment:
        return "private_direct_follow_up"
    return "private_unclear"


def pick_digest_v5_snippets(candidate: dict[str, Any]) -> list[dict[str, Any]]:
    messages = candidate.get("messages", [])
    if not messages:
        return []

    if candidate.get("chatType") == "group":
        return pick_digest_v3_snippets(candidate)

    actionable_index = next(
        (
            index
            for index in range(len(messages) - 1, -1, -1)
            if is_digest_actionable_inbound(messages[index], candidate.get("chatType", ""))
        ),
        None,
    )

    picked: list[dict[str, Any]] = []
    seen: set[int] = set()

    if actionable_index is not None:
        start = max(0, actionable_index - 2)
        end = min(len(messages), actionable_index + 3)
        for message in [messages[-1], *messages[start:end]]:
            if message["messageId"] not in seen:
                seen.add(message["messageId"])
                picked.append(message)
        return picked

    for message in messages[-3:]:
        if message["messageId"] not in seen:
            seen.add(message["messageId"])
            picked.append(message)
    return picked


def digest_v5_user_message(query: str, scope: str, candidates: list[dict[str, Any]]) -> str:
    lines = [
        f'User query: "{query}"',
        f"Scope: {scope}",
        "Return one result for every candidate chatId.",
        "Each candidate includes structured ownership fields. Group cues are precision-first; private cues are recall-friendly but still secondary to clear closure.",
        "",
        "Candidate chats:",
    ]

    for candidate in candidates:
        messages = candidate.get("messages", [])
        latest = messages[-1] if messages else None
        latest_inbound = next((message for message in reversed(messages) if message.get("senderFirstName") != "[ME]"), None)
        latest_outbound = next((message for message in reversed(messages) if message.get("senderFirstName") == "[ME]"), None)
        latest_actionable_inbound = next(
            (
                message
                for message in reversed(messages)
                if is_digest_actionable_inbound(message, candidate.get("chatType", ""))
            ),
            None,
        )
        latest_closure = next(
            (
                message
                for message in reversed(messages)
                if looks_like_closure(message.get("text", ""), from_me=message.get("senderFirstName") == "[ME]")
                or inbound_message_implies_contact_owns_next_step(message.get("text", ""))
            ),
            None,
        )
        latest_commitment = next(
            (
                message
                for message in reversed(messages)
                if message.get("senderFirstName") == "[ME]" and looks_like_commitment_from_me(message.get("text", ""))
            ),
            None,
        )
        last_actionable_mentions = extract_handle_mentions(latest_actionable_inbound.get("text", "") if latest_actionable_inbound else "")
        unresolved_after_me = bool(
            latest_actionable_inbound
            and (not latest_outbound or latest_actionable_inbound["messageId"] > latest_outbound["messageId"])
        )
        closure_after_actionable = bool(
            latest_actionable_inbound
            and latest_closure
            and latest_closure["messageId"] > latest_actionable_inbound["messageId"]
        )
        ownership_hint = group_ownership_hint(
            candidate,
            latest_actionable_inbound,
            latest_commitment,
            latest_closure,
            latest_outbound,
            closure_after_actionable,
            unresolved_after_me,
            last_actionable_mentions,
        )
        private_hint = private_ownership_hint(
            latest_actionable_inbound,
            latest_commitment,
            latest_closure,
            latest_outbound,
            closure_after_actionable,
            unresolved_after_me,
        )
        latest_actionable_text = latest_actionable_inbound.get("text", "") if latest_actionable_inbound else ""

        lines.append("")
        lines.append("---")
        lines.append(f"chatId: {candidate['chatId']}")
        lines.append(f"chatName: {candidate['chatName']}")
        lines.append(f"chatType: {candidate['chatType']}")
        lines.append(f"unreadCount: {candidate['unreadCount']}")
        if candidate.get("memberCount") is not None:
            lines.append(f"memberCount: {candidate['memberCount']}")
        lines.append(
            "weakLocalHeuristic: "
            f"localSignal={candidate['localSignal']} "
            f"pipelineHint={candidate.get('pipelineHint', 'uncategorized')} "
            f"replyOwed={candidate.get('replyOwed')} "
            f"strictReplySignal={candidate.get('strictReplySignal')} "
            f"effectiveGroupReplySignal={candidate.get('effectiveGroupReplySignal')}"
        )
        lines.append(f"groupOwnershipHint: {ownership_hint}")
        if candidate.get("chatType") != "group":
            lines.append(f"privateOwnershipHint: {private_hint}")
            lines.append(
                "privateReplySignal: "
                f"localSignal={candidate['localSignal']} "
                f"replyOwed={candidate.get('replyOwed')} "
                f"strictReplySignal={candidate.get('strictReplySignal')}"
            )
        lines.append(f"latestSpeaker: {latest['senderFirstName'] if latest else 'none'}")
        lines.append(f"latestInboundSpeaker: {latest_inbound['senderFirstName'] if latest_inbound else 'none'}")
        lines.append(f"latestOutboundExists: {latest_outbound is not None}")
        lines.append(f"latestActionableInboundSpeaker: {latest_actionable_inbound['senderFirstName'] if latest_actionable_inbound else 'none'}")
        lines.append(f"latestActionableInboundMentionsHandles: {', '.join(last_actionable_mentions) if last_actionable_mentions else 'none'}")
        lines.append(f"broadcastStyleLatestActionable: {looks_broadcast_group_ask(latest_actionable_text)}")
        lines.append(f"directSecondPersonLatestActionable: {looks_direct_second_person_ask(latest_actionable_text)}")
        lines.append(f"latestCommitmentFromMe: {latest_commitment is not None}")
        lines.append(f"latestInboundOwnsNextStep: {bool(latest_closure and inbound_message_implies_contact_owns_next_step(latest_closure.get('text', '')))}")
        lines.append(f"closureAfterLatestActionable: {closure_after_actionable}")
        lines.append(f"latestActionableStillAfterMyReply: {unresolved_after_me}")
        if latest_actionable_inbound:
            lines.append(f"latestActionableInboundText: {latest_actionable_inbound['text']}")
        if latest_commitment:
            lines.append(f"latestCommitmentText: {latest_commitment['text']}")
        if latest_closure:
            lines.append(f"latestClosureText: {latest_closure['text']}")
        lines.append("Key snippets:")
        for message in pick_digest_v5_snippets(candidate):
            lines.append(format_message(message))

    return "\n".join(lines)


def digest_v6_user_message(query: str, scope: str, candidates: list[dict[str, Any]]) -> str:
    lines = [
        f'User query: "{query}"',
        f"Scope: {scope}",
        "Return one result for every candidate chatId.",
        "Each candidate includes structured ownership fields plus a wider group context window to separate ambient technical discussion from real reply obligations.",
        "",
        "Candidate chats:",
    ]

    for candidate in candidates:
        messages = candidate.get("messages", [])
        latest = messages[-1] if messages else None
        latest_inbound = next((message for message in reversed(messages) if message.get("senderFirstName") != "[ME]"), None)
        latest_outbound = next((message for message in reversed(messages) if message.get("senderFirstName") == "[ME]"), None)
        actionable_index = next(
            (
                index
                for index in range(len(messages) - 1, -1, -1)
                if is_digest_actionable_inbound(messages[index], candidate.get("chatType", ""))
            ),
            None,
        )
        latest_actionable_inbound = messages[actionable_index] if actionable_index is not None else None
        latest_closure = next(
            (
                message
                for message in reversed(messages)
                if looks_like_closure(message.get("text", ""), from_me=message.get("senderFirstName") == "[ME]")
                or inbound_message_implies_contact_owns_next_step(message.get("text", ""))
            ),
            None,
        )
        latest_commitment = next(
            (
                message
                for message in reversed(messages)
                if message.get("senderFirstName") == "[ME]" and looks_like_commitment_from_me(message.get("text", ""))
            ),
            None,
        )
        last_actionable_mentions = extract_handle_mentions(latest_actionable_inbound.get("text", "") if latest_actionable_inbound else "")
        unresolved_after_me = bool(
            latest_actionable_inbound
            and (not latest_outbound or latest_actionable_inbound["messageId"] > latest_outbound["messageId"])
        )
        closure_after_actionable = bool(
            latest_actionable_inbound
            and latest_closure
            and latest_closure["messageId"] > latest_actionable_inbound["messageId"]
        )
        ownership_hint = group_ownership_hint(
            candidate,
            latest_actionable_inbound,
            latest_commitment,
            latest_closure,
            latest_outbound,
            closure_after_actionable,
            unresolved_after_me,
            last_actionable_mentions,
        )
        private_hint = private_ownership_hint(
            latest_actionable_inbound,
            latest_commitment,
            latest_closure,
            latest_outbound,
            closure_after_actionable,
            unresolved_after_me,
        )
        latest_actionable_text = latest_actionable_inbound.get("text", "") if latest_actionable_inbound else ""
        earlier_request_for_input = latest_earlier_request_for_input(messages, actionable_index)

        lines.append("")
        lines.append("---")
        lines.append(f"chatId: {candidate['chatId']}")
        lines.append(f"chatName: {candidate['chatName']}")
        lines.append(f"chatType: {candidate['chatType']}")
        lines.append(f"unreadCount: {candidate['unreadCount']}")
        if candidate.get("memberCount") is not None:
            lines.append(f"memberCount: {candidate['memberCount']}")
        lines.append(
            "weakLocalHeuristic: "
            f"localSignal={candidate['localSignal']} "
            f"pipelineHint={candidate.get('pipelineHint', 'uncategorized')} "
            f"replyOwed={candidate.get('replyOwed')} "
            f"strictReplySignal={candidate.get('strictReplySignal')} "
            f"effectiveGroupReplySignal={candidate.get('effectiveGroupReplySignal')}"
        )
        lines.append(f"groupOwnershipHint: {ownership_hint}")
        if candidate.get("chatType") != "group":
            lines.append(f"privateOwnershipHint: {private_hint}")
            lines.append(
                "privateReplySignal: "
                f"localSignal={candidate['localSignal']} "
                f"replyOwed={candidate.get('replyOwed')} "
                f"strictReplySignal={candidate.get('strictReplySignal')}"
            )
        lines.append(f"latestSpeaker: {latest['senderFirstName'] if latest else 'none'}")
        lines.append(f"latestInboundSpeaker: {latest_inbound['senderFirstName'] if latest_inbound else 'none'}")
        lines.append(f"latestOutboundExists: {latest_outbound is not None}")
        lines.append(f"latestActionableInboundSpeaker: {latest_actionable_inbound['senderFirstName'] if latest_actionable_inbound else 'none'}")
        lines.append(f"latestActionableInboundMentionsHandles: {', '.join(last_actionable_mentions) if last_actionable_mentions else 'none'}")
        if candidate.get("chatType") == "group":
            lines.append(f"broadcastStyleLatestActionable: {looks_broadcast_group_ask(latest_actionable_text)}")
            lines.append(f"directSecondPersonLatestActionable: {looks_direct_second_person_ask(latest_actionable_text)}")
            lines.append(f"explicitSecondPersonLatestActionable: {looks_direct_second_person_ask(latest_actionable_text)}")
            lines.append(f"latestActionableLooksExplanatory: {looks_explanatory_group_reply(latest_actionable_text)}")
            lines.append(f"ccStyleHandleMentions: {looks_cc_style_mentions(latest_actionable_text)}")
            lines.append(f"earlierRequestForInputExists: {earlier_request_for_input is not None}")
        lines.append(f"latestCommitmentFromMe: {latest_commitment is not None}")
        lines.append(f"latestInboundOwnsNextStep: {bool(latest_closure and inbound_message_implies_contact_owns_next_step(latest_closure.get('text', '')))}")
        lines.append(f"closureAfterLatestActionable: {closure_after_actionable}")
        lines.append(f"latestActionableStillAfterMyReply: {unresolved_after_me}")
        if candidate.get("chatType") == "group" and earlier_request_for_input:
            lines.append(f"earlierRequestForInputText: {earlier_request_for_input['text']}")
        if latest_actionable_inbound:
            lines.append(f"latestActionableInboundText: {latest_actionable_inbound['text']}")
        if latest_commitment:
            lines.append(f"latestCommitmentText: {latest_commitment['text']}")
        if latest_closure:
            lines.append(f"latestClosureText: {latest_closure['text']}")
        lines.append("Key snippets:")
        if candidate.get("chatType") == "group":
            snippets = pick_digest_v6_group_snippets(candidate)
        else:
            snippets = pick_digest_v5_snippets(candidate)
        for message in snippets:
            lines.append(format_message(message))

    return "\n".join(lines)


def format_message(message: dict[str, Any]) -> str:
    return (
        f"[messageId: {message['messageId']}] "
        f"[{message['relativeTimestamp']}] "
        f"{message['senderFirstName']}: {message['text']}"
    )


def pick_compact_snippets(candidate: dict[str, Any]) -> list[dict[str, Any]]:
    messages = candidate.get("messages", [])
    if not messages:
        return []
    latest = messages[-1]
    inbound = next((message for message in reversed(messages) if message.get("senderFirstName") != "[ME]"), None)
    outbound = next((message for message in reversed(messages) if message.get("senderFirstName") == "[ME]"), None)
    actionable_inbound = next(
        (
            message
            for message in reversed(messages)
            if is_digest_actionable_inbound(message, candidate.get("chatType", ""))
        ),
        None,
    )
    closure = next(
        (
            message
            for message in reversed(messages)
            if looks_like_closure(message.get("text", ""), from_me=message.get("senderFirstName") == "[ME]")
        ),
        None,
    )
    picked: list[dict[str, Any]] = []
    seen: set[int] = set()
    for message in [latest, actionable_inbound, inbound, outbound, closure]:
        if message and message["messageId"] not in seen:
            seen.add(message["messageId"])
            picked.append(message)
    return picked


def pick_digest_v2_snippets(candidate: dict[str, Any]) -> list[dict[str, Any]]:
    messages = candidate.get("messages", [])
    if not messages:
        return []

    latest = messages[-1]
    latest_inbound = next((message for message in reversed(messages) if message.get("senderFirstName") != "[ME]"), None)
    latest_outbound = next((message for message in reversed(messages) if message.get("senderFirstName") == "[ME]"), None)
    latest_actionable = next(
        (
            message
            for message in reversed(messages)
            if is_digest_actionable_inbound(message, candidate.get("chatType", ""))
        ),
        None,
    )
    latest_commitment = next(
        (
            message
            for message in reversed(messages)
            if message.get("senderFirstName") == "[ME]" and looks_like_commitment_from_me(message.get("text", ""))
        ),
        None,
    )
    latest_closure = next(
        (
            message
            for message in reversed(messages)
            if looks_like_closure(message.get("text", ""), from_me=message.get("senderFirstName") == "[ME]")
        ),
        None,
    )

    picked: list[dict[str, Any]] = []
    seen: set[int] = set()
    for message in [latest, latest_actionable, latest_commitment, latest_inbound, latest_outbound, latest_closure]:
        if message and message["messageId"] not in seen:
            seen.add(message["messageId"])
            picked.append(message)
    return picked


def pick_digest_v3_snippets(candidate: dict[str, Any]) -> list[dict[str, Any]]:
    messages = candidate.get("messages", [])
    if not messages:
        return []

    latest = messages[-1]
    latest_inbound = next((message for message in reversed(messages) if message.get("senderFirstName") != "[ME]"), None)
    latest_outbound = next((message for message in reversed(messages) if message.get("senderFirstName") == "[ME]"), None)
    actionable_index = next(
        (
            index
            for index in range(len(messages) - 1, -1, -1)
            if is_digest_actionable_inbound(messages[index], candidate.get("chatType", ""))
        ),
        None,
    )
    latest_actionable = messages[actionable_index] if actionable_index is not None else None
    before_actionable = messages[actionable_index - 1] if actionable_index is not None and actionable_index - 1 >= 0 else None
    after_actionable = messages[actionable_index + 1] if actionable_index is not None and actionable_index + 1 < len(messages) else None
    latest_commitment = next(
        (
            message
            for message in reversed(messages)
            if message.get("senderFirstName") == "[ME]" and looks_like_commitment_from_me(message.get("text", ""))
        ),
        None,
    )
    latest_closure = next(
        (
            message
            for message in reversed(messages)
            if looks_like_closure(message.get("text", ""), from_me=message.get("senderFirstName") == "[ME]")
            or inbound_message_implies_contact_owns_next_step(message.get("text", ""))
        ),
        None,
    )

    picked: list[dict[str, Any]] = []
    seen: set[int] = set()
    for message in [latest, latest_actionable, before_actionable, after_actionable, latest_commitment, latest_inbound, latest_outbound, latest_closure]:
        if message and message["messageId"] not in seen:
            seen.add(message["messageId"])
            picked.append(message)
    return picked


def build_user_message(query: str, scope: str, candidates: list[dict[str, Any]], payload_variant: str) -> str:
    if payload_variant == "digest_v2":
        return digest_v2_user_message(query, scope, candidates)
    if payload_variant == "digest_v3":
        return digest_v3_user_message(query, scope, candidates)
    if payload_variant == "digest_v4":
        return digest_v4_user_message(query, scope, candidates)
    if payload_variant == "digest_v5":
        return digest_v5_user_message(query, scope, candidates)
    if payload_variant == "digest_v6":
        return digest_v6_user_message(query, scope, candidates)
    return compact_v1_user_message(query, scope, candidates)


def classification_values_for_prompt_variant(prompt_variant: str) -> list[str]:
    if "tiered_review" in prompt_variant:
        return ["on_me", "worth_checking", "on_them", "quiet", "need_more"]
    return ["on_me", "on_them", "quiet", "need_more"]


def response_format_for_candidates(candidates: list[dict[str, Any]], prompt_variant: str) -> dict[str, Any]:
    candidate_ids = [candidate["chatId"] for candidate in candidates]
    classification_values = classification_values_for_prompt_variant(prompt_variant)
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
                                "classification": {"type": "string", "enum": classification_values},
                                "urgency": {"type": "string", "enum": ["high", "medium", "low"]},
                                "reason": {"type": "string"},
                                "suggestedAction": {"type": "string"},
                                "confidence": {"type": "number", "minimum": 0, "maximum": 1},
                                "supportingMessageIds": {"type": "array", "items": {"type": "integer"}},
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


def estimate_cost(usage: dict[str, int], tier: str) -> Optional[float]:
    rates = PRICING["gpt-5.4-mini"].get(tier)
    if not rates:
        return None
    return (
        usage["uncached_prompt_tokens"] / 1_000_000 * rates["input"]
        + usage["cached_prompt_tokens"] / 1_000_000 * rates["cached_input"]
        + usage["completion_tokens"] / 1_000_000 * rates["output"]
    )


def load_api_key(path: Path) -> str:
    if os.environ.get("OPENAI_API_KEY"):
        return os.environ["OPENAI_API_KEY"]
    candidate_paths = [path, *PROVIDER_SCOPED_API_KEY_PATHS, LEGACY_API_KEY_PATH]
    for candidate_path in candidate_paths:
        if not candidate_path.exists():
            continue
        value = candidate_path.read_text().strip()
        if value:
            return value
    return ""


def call_openai(
    api_key: str,
    prompt_variant: str,
    payload_variant: str,
    query: str,
    scope: str,
    candidates: list[dict[str, Any]],
    batch_index: int,
) -> dict[str, Any]:
    body: dict[str, Any] = {
        "model": "gpt-5.4-mini",
        "messages": [
            {"role": "system", "content": PROMPT_VARIANTS[prompt_variant]},
            {"role": "user", "content": build_user_message(query, scope, candidates, payload_variant)},
        ],
        "response_format": response_format_for_candidates(candidates, prompt_variant),
        "prompt_cache_key": f"reply-queue-{prompt_variant}-{payload_variant}",
    }

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
            f"Cardinality mismatch in batch {batch_index}: expected {len(candidates)} / {sorted(expected_ids)} "
            f"but got {len(results)} / {sorted(returned_ids)}"
        )

    usage = extract_usage(payload)
    return {
        "batch_index": batch_index,
        "elapsed_ms": elapsed_ms,
        "size": len(candidates),
        "usage": usage,
        "results": results,
    }


def chunk_candidates(candidates: list[dict[str, Any]], size: int) -> list[list[dict[str, Any]]]:
    return [candidates[index:index + size] for index in range(0, len(candidates), size)]


def run_variant(api_key: str, snapshot: dict[str, Any], variant: VariantRun, batch_size: int) -> dict[str, Any]:
    candidates = snapshot["candidates"][:48]
    batches = chunk_candidates(candidates, batch_size)
    started = time.perf_counter()
    batch_outputs: list[dict[str, Any]] = []

    with ThreadPoolExecutor(max_workers=len(batches)) as executor:
        future_map = {
            executor.submit(
                call_openai,
                api_key,
                variant.prompt_variant,
                variant.payload_variant,
                snapshot["query"],
                snapshot["scope"],
                batch,
                index,
            ): index
            for index, batch in enumerate(batches, start=1)
        }
        for future in as_completed(future_map):
            batch_outputs.append(future.result())

    batch_outputs.sort(key=lambda item: item["batch_index"])
    wall_clock_ms = int((time.perf_counter() - started) * 1000)

    total_usage = {"prompt_tokens": 0, "cached_prompt_tokens": 0, "uncached_prompt_tokens": 0, "completion_tokens": 0}
    flat_results: list[dict[str, Any]] = []
    summed_batch_ms = 0
    for batch in batch_outputs:
        summed_batch_ms += batch["elapsed_ms"]
        for key in total_usage:
            total_usage[key] += batch["usage"][key]
        flat_results.extend(batch["results"])

    flat_results.sort(key=lambda item: item["chatId"])
    return {
        "name": variant.name,
        "model": "gpt-5.4-mini",
        "candidate_limit": len(candidates),
        "batch_size": batch_size,
        "batch_count": len(batches),
        "prompt_variant": variant.prompt_variant,
        "payload_variant": variant.payload_variant,
        "wall_clock_ms": wall_clock_ms,
        "summed_batch_ms": summed_batch_ms,
        "estimated_standard_cost_usd": estimate_cost(total_usage, "standard"),
        "total_usage": total_usage,
        "on_me_chat_ids": sorted(item["chatId"] for item in flat_results if item["classification"] == "on_me"),
        "worth_checking_chat_ids": sorted(item["chatId"] for item in flat_results if item["classification"] == "worth_checking"),
        "surfaced_chat_ids": sorted(item["chatId"] for item in flat_results if item["classification"] in {"on_me", "worth_checking"}),
        "need_more_chat_ids": sorted(item["chatId"] for item in flat_results if item["classification"] == "need_more"),
        "results": flat_results,
        "batches": [
            {
                "batch_index": batch["batch_index"],
                "elapsed_ms": batch["elapsed_ms"],
                "size": batch["size"],
                "usage": batch["usage"],
                "on_me_chat_ids": sorted(item["chatId"] for item in batch["results"] if item["classification"] == "on_me"),
                "worth_checking_chat_ids": sorted(item["chatId"] for item in batch["results"] if item["classification"] == "worth_checking"),
                "need_more_chat_ids": sorted(item["chatId"] for item in batch["results"] if item["classification"] == "need_more"),
            }
            for batch in batch_outputs
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Run offline reply-queue prompt/digest variants against the saved 48-chat snapshot.")
    parser.add_argument("--snapshot", type=Path, default=DEFAULT_SNAPSHOT_PATH)
    parser.add_argument("--api-key-file", type=Path, default=DEFAULT_API_KEY_PATH)
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    parser.add_argument("--batch-size", type=int, default=12)
    args = parser.parse_args()

    if not args.snapshot.exists():
        print(f"Snapshot not found: {args.snapshot}", file=sys.stderr)
        return 1

    snapshot = json.loads(args.snapshot.read_text())
    api_key = load_api_key(args.api_key_file)
    args.out_dir.mkdir(parents=True, exist_ok=True)

    captured_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    summary: list[dict[str, Any]] = []
    for variant in VARIANT_RUNS:
        print(f"Running offline variant: {variant.name}", file=sys.stderr)
        payload = run_variant(api_key, snapshot, variant, args.batch_size)
        payload["capturedAt"] = captured_at
        payload["snapshotQuery"] = snapshot["query"]
        payload["snapshotScope"] = snapshot["scope"]
        payload["snapshotStrategy"] = snapshot.get("strategy")
        output_path = args.out_dir / f"{variant.name}.json"
        output_path.write_text(json.dumps(payload, indent=2, sort_keys=True))
        summary.append(
            {
                "name": payload["name"],
                "wall_clock_ms": payload["wall_clock_ms"],
                "summed_batch_ms": payload["summed_batch_ms"],
                "on_me_count": len(payload["on_me_chat_ids"]),
                "need_more_count": len(payload["need_more_chat_ids"]),
                "estimated_standard_cost_usd": payload["estimated_standard_cost_usd"],
                "output_path": str(output_path),
            }
        )

    print(json.dumps({"capturedAt": captured_at, "variants": summary}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
