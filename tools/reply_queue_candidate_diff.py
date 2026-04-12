#!/usr/bin/env python3
import argparse
import json
import re
import sys
import textwrap
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Optional


REPO_ROOT = Path("/Users/pratyushrungta/telegraham")
APP_SUPPORT = Path.home() / "Library" / "Application Support" / "Pidgy"
DEFAULT_GOLD_PATH = REPO_ROOT / "evals" / "reply_queue_manual_gold_mixed_recent_48.json"
DEFAULT_SNAPSHOT_DIR = APP_SUPPORT / "debug" / "reply_queue_candidate_snapshots"


@dataclass(frozen=True)
class GoldLabel:
    chat_id: int
    chat_name: str
    chat_type: str
    label: str
    reason: str


@dataclass(frozen=True)
class Prediction:
    chat_id: int
    classification: str
    confidence: Optional[float]
    reason: str
    suggested_action: str
    support_ids: list[int]
    source: str


def load_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text())
    except FileNotFoundError as error:
        raise SystemExit(f"File not found: {path}") from error
    except json.JSONDecodeError as error:
        raise SystemExit(f"Invalid JSON in {path}: {error}") from error


def load_gold(path: Path) -> dict[int, GoldLabel]:
    payload = load_json(path)
    labels: dict[int, GoldLabel] = {}
    for chat_id, item in payload.get("labels", {}).items():
        labels[int(chat_id)] = GoldLabel(
            chat_id=int(chat_id),
            chat_name=item.get("chatName", str(chat_id)),
            chat_type=item.get("chatType", "unknown"),
            label=item.get("label", "unknown"),
            reason=item.get("reason", ""),
        )
    return labels


def is_group(chat_type: str) -> bool:
    return chat_type.lower() == "group"


def normalize_text(value: Any) -> str:
    return " ".join(str(value or "").split())


def extract_handle_mentions(text: str) -> list[str]:
    return sorted(set(match.lower() for match in re.findall(r"@\w+", text or "")))


def looks_actionable(text: str) -> bool:
    compact = re.sub(r"https?://\S+", " ", normalize_text(text).lower())
    if not compact:
        return False
    if "?" in compact:
        return True
    signals = [
        "please",
        "pls",
        "can you",
        "could you",
        "let me know",
        "share",
        "send",
        "update",
        "review",
        "check",
        "approve",
        "confirm",
        "eta",
        "join",
        "when",
        "what",
        "how",
        "where",
        "reply",
        "follow up",
        "follow-up",
        "look into",
        "take a look",
        "help",
        "thoughts",
        "status",
    ]
    return any(signal in compact for signal in signals)


def looks_like_closure(text: str, from_me: bool) -> bool:
    compact = normalize_text(text).lower()
    if not compact:
        return False
    closure_signals = [
        "done",
        "thanks",
        "thank you",
        "got it",
        "noted",
        "sounds good",
        "perfect",
        "resolved",
        "on it",
        "will do",
        "will share",
        "will send",
    ]
    if from_me:
        return any(compact == signal or signal in compact for signal in closure_signals)
    passive_signals = ["works", "all good", "fine", "cool", "great", "awesome"]
    return any(compact == signal or signal in compact for signal in (closure_signals + passive_signals))


def looks_like_commitment_from_me(text: str) -> bool:
    compact = normalize_text(text).lower()
    if not compact:
        return False
    commitment_signals = [
        "i'll",
        "i will",
        "on it",
        "will do",
        "will share",
        "will send",
        "will check",
        "let me",
        "bhejta",
        "check karta",
        "i can",
        "will reply",
        "will update",
    ]
    return any(signal in compact for signal in commitment_signals)


def load_candidate_snapshot(path: Path) -> dict[int, dict[str, Any]]:
    payload = load_json(path)
    if "candidates" not in payload:
        raise SystemExit(f"Snapshot does not look like a candidate file: {path}")

    candidates: dict[int, dict[str, Any]] = {}
    for item in payload.get("candidates", []):
        chat_id = int(item["chatId"])
        candidates[chat_id] = item
    return candidates


def derive_snapshot_path(
    input_path: Path,
    payload: dict[str, Any],
    override: Optional[Path],
) -> Optional[Path]:
    if override:
        return override

    if "candidates" in payload:
        return input_path

    explicit = payload.get("snapshotPath") or payload.get("snapshot")
    if isinstance(explicit, str) and explicit.strip():
        candidate = Path(explicit)
        if candidate.exists():
            return candidate

    strategy = payload.get("snapshotStrategy")
    if isinstance(strategy, str) and strategy.strip():
        derived_name = strategy.replace(":", "_") + ".json"
        candidate = DEFAULT_SNAPSHOT_DIR / derived_name
        if candidate.exists():
            return candidate

    default_candidate = DEFAULT_SNAPSHOT_DIR / "mixed_recent_48.json"
    if default_candidate.exists():
        return default_candidate

    return None


def extract_result_predictions(payload: dict[str, Any]) -> dict[int, Prediction]:
    predictions: dict[int, Prediction] = {}

    if "results" in payload and isinstance(payload["results"], list):
        for item in payload["results"]:
            if not isinstance(item, dict) or "chatId" not in item:
                continue
            chat_id = int(item["chatId"])
            predictions[chat_id] = Prediction(
                chat_id=chat_id,
                classification=str(item.get("classification", "unknown")),
                confidence=float(item["confidence"]) if item.get("confidence") is not None else None,
                reason=normalize_text(item.get("reason", "")),
                suggested_action=normalize_text(item.get("suggestedAction", "")),
                support_ids=[int(x) for x in item.get("supportingMessageIds", [])],
                source="benchmark_result",
            )
        return predictions

    if "candidates" in payload and isinstance(payload["candidates"], list):
        for item in payload["candidates"]:
            if not isinstance(item, dict) or "chatId" not in item:
                continue
            chat_id = int(item["chatId"])
            selected = bool(item.get("finalIncluded"))
            predictions[chat_id] = Prediction(
                chat_id=chat_id,
                classification="on_me" if selected else "not_selected",
                confidence=None,
                reason=f"snapshot.finalIncluded={selected} localSignal={item.get('localSignal', 'unknown')}",
                suggested_action="",
                support_ids=[],
                source="snapshot_selection",
            )
        return predictions

    raise SystemExit("Input JSON does not look like a benchmark result or candidate snapshot.")


def pick_key_messages(candidate: dict[str, Any]) -> list[dict[str, Any]]:
    messages = candidate.get("messages", []) or []
    if not messages:
        return []

    latest = messages[-1]
    latest_inbound = next((message for message in reversed(messages) if message.get("senderFirstName") != "[ME]"), None)
    latest_outbound = next((message for message in reversed(messages) if message.get("senderFirstName") == "[ME]"), None)
    latest_actionable = next(
        (
            message
            for message in reversed(messages)
            if message.get("senderFirstName") != "[ME]" and looks_actionable(message.get("text", ""))
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
    for message in [latest_actionable, latest_commitment, latest_closure, latest_inbound, latest_outbound, latest]:
        if message and int(message["messageId"]) not in seen:
            seen.add(int(message["messageId"]))
            picked.append(message)
    return picked


def format_message(message: dict[str, Any], support_ids: set[int]) -> str:
    sender = str(message.get("senderFirstName", "Unknown"))
    text = normalize_text(message.get("text", ""))
    tags: list[str] = []
    if sender == "[ME]":
        tags.append("ME")
        if looks_like_commitment_from_me(text):
            tags.append("COMMIT")
    else:
        if looks_actionable(text):
            tags.append("ASK")
        if looks_like_closure(text, from_me=False):
            tags.append("CLOSE")
        mentions = extract_handle_mentions(text)
        if mentions:
            tags.append("MENTION " + ",".join(mentions))

    if int(message.get("messageId", 0)) in support_ids:
        tags.insert(0, "SUPPORT")

    tag_str = f"[{' | '.join(tags)}] " if tags else ""
    return f"{tag_str}[{message.get('relativeTimestamp', '?')}] {sender}: {text or '[non-text message]'}"


def candidate_ownership_lines(candidate: dict[str, Any]) -> list[str]:
    messages = candidate.get("messages", []) or []
    latest = messages[-1] if messages else None
    latest_inbound = next((message for message in reversed(messages) if message.get("senderFirstName") != "[ME]"), None)
    latest_outbound = next((message for message in reversed(messages) if message.get("senderFirstName") == "[ME]"), None)
    latest_actionable = next(
        (
            message
            for message in reversed(messages)
            if message.get("senderFirstName") != "[ME]" and looks_actionable(message.get("text", ""))
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

    actionable_mentions = extract_handle_mentions(latest_actionable.get("text", "")) if latest_actionable else []
    closure_after_actionable = bool(
        latest_actionable and latest_closure and int(latest_closure["messageId"]) > int(latest_actionable["messageId"])
    )
    actionable_after_me = bool(
        latest_actionable and (not latest_outbound or int(latest_actionable["messageId"]) > int(latest_outbound["messageId"]))
    )

    lines = []
    lines.append(
        "OWN  latestActionable="
        + (
            f"{latest_actionable.get('senderFirstName')} -> {normalize_text(latest_actionable.get('text', ''))}"
            if latest_actionable
            else "none"
        )
    )
    lines.append(
        "OWN  latestCommitmentFromMe="
        + (
            normalize_text(latest_commitment.get("text", ""))
            if latest_commitment
            else "none"
        )
    )
    lines.append(
        "OWN  latestClosure="
        + (
            f"{latest_closure.get('senderFirstName')} -> {normalize_text(latest_closure.get('text', ''))}"
            if latest_closure
            else "none"
        )
    )
    lines.append(f"OWN  closureAfterActionable={closure_after_actionable}")
    lines.append(f"OWN  actionableAfterMyReply={actionable_after_me}")
    lines.append(
        "OWN  actionableMentions="
        + (", ".join(actionable_mentions) if actionable_mentions else "none")
    )
    lines.append(f"OWN  latestInbound={normalize_text(latest_inbound.get('text', '')) if latest_inbound else 'none'}")
    lines.append(f"OWN  latestOutbound={normalize_text(latest_outbound.get('text', '')) if latest_outbound else 'none'}")
    lines.append(f"OWN  latestVisible={normalize_text(latest.get('text', '')) if latest else 'none'}")
    return lines


def infer_group_status(gold: GoldLabel) -> str:
    return "group" if gold.chat_type == "group" else "private"


def sort_diff_ids(ids: Iterable[int], labels: dict[int, GoldLabel], candidates: dict[int, dict[str, Any]]) -> list[int]:
    def key(chat_id: int) -> tuple[int, float, str]:
        gold = labels.get(chat_id)
        candidate = candidates.get(chat_id, {})
        is_private = 1 if gold and gold.chat_type != "group" else 0
        latest_timestamp = float(candidate.get("latestMessageDate") or 0.0)
        name = (gold.chat_name if gold else candidate.get("chatName", str(chat_id))).lower()
        return (is_private, -latest_timestamp, name)

    return sorted(ids, key=key)


def wrap(prefix: str, value: str, indent: str = "  ", width: int = 110) -> list[str]:
    if not value:
        return [f"{indent}{prefix}: "]
    available = max(20, width - len(indent) - len(prefix) - 2)
    lines = textwrap.wrap(value, width=available) or [""]
    rendered = [f"{indent}{prefix}: {lines[0]}"]
    pad = " " * (len(indent) + len(prefix) + 2)
    rendered.extend(f"{pad}{line}" for line in lines[1:])
    return rendered


def render_entry(
    kind: str,
    chat_id: int,
    labels: dict[int, GoldLabel],
    predictions: dict[int, Prediction],
    candidates: dict[int, dict[str, Any]],
) -> str:
    gold = labels.get(chat_id)
    candidate = candidates.get(chat_id, {})
    prediction = predictions.get(chat_id)
    title_name = gold.chat_name if gold else candidate.get("chatName", str(chat_id))
    title_type = gold.chat_type if gold else candidate.get("chatType", "unknown")
    lines: list[str] = []
    lines.append("-" * 96)
    lines.append(
        f"{kind} | {title_name} | id={chat_id} | {infer_group_status(gold) if gold else title_type}"
    )
    if gold:
        lines.extend(wrap("GOLD", f"{gold.label} - {gold.reason}"))
    else:
        lines.extend(wrap("GOLD", "missing gold label"))
    if prediction:
        confidence = f" ({prediction.confidence:.2f})" if prediction.confidence is not None else ""
        lines.extend(
            wrap(
                "PRED",
                f"{prediction.classification}{confidence} - {prediction.reason}".rstrip(" -"),
            )
        )
        if prediction.suggested_action:
            lines.extend(wrap("ACTN", prediction.suggested_action))
        if prediction.support_ids:
            lines.extend(wrap("SUPP", ", ".join(str(item) for item in prediction.support_ids)))
    else:
        lines.extend(wrap("PRED", "missing prediction"))

    meta_bits = [
        f"localSignal={candidate.get('localSignal', 'n/a')}",
        f"pipelineHint={candidate.get('pipelineHint', 'n/a')}",
        f"replyOwed={candidate.get('replyOwed', 'n/a')}",
        f"strictReplySignal={candidate.get('strictReplySignal', 'n/a')}",
        f"effectiveGroupReplySignal={candidate.get('effectiveGroupReplySignal', 'n/a')}",
        f"sentToAI={candidate.get('sentToAI', 'n/a')}",
        f"finalIncluded={candidate.get('finalIncluded', 'n/a')}",
        f"unread={candidate.get('unreadCount', 'n/a')}",
        f"latest={candidate.get('latestMessageDate', 0.0):.0f}",
    ]
    if candidate.get("memberCount") is not None:
        meta_bits.append(f"memberCount={candidate.get('memberCount')}")
    lines.extend(wrap("META", " | ".join(meta_bits)))
    lines.extend(candidate_ownership_lines(candidate))

    messages = candidate.get("messages", []) or []
    if messages:
        support_ids = set(prediction.support_ids if prediction else [])
        lines.append("MSG  key timeline:")
        for message in pick_key_messages(candidate):
            lines.append(f"  - {format_message(message, support_ids)}")
    else:
        lines.append("MSG  no candidate messages available")
    return "\n".join(lines)


def extract_prediction_ids(payload: dict[str, Any]) -> set[int]:
    predictions = extract_result_predictions(payload)
    return {
        chat_id
        for chat_id, prediction in predictions.items()
        if prediction.classification == "on_me"
    }


def summarize_counts(gold: dict[int, GoldLabel], predicted: set[int]) -> dict[str, int]:
    gold_positive = {chat_id for chat_id, label in gold.items() if label.label == "on_me"}
    lenient_positive = {chat_id for chat_id, label in gold.items() if label.label in {"on_me", "maybe"}}
    return {
        "gold_on_me": len(gold_positive),
        "gold_maybe": sum(1 for label in gold.values() if label.label == "maybe"),
        "predicted_on_me": len(predicted),
        "fp_strict": len(predicted - gold_positive),
        "fn_strict": len(gold_positive - predicted),
        "fp_lenient": len(predicted - lenient_positive),
        "fn_lenient": len(lenient_positive - predicted),
    }


def resolve_input_paths(
    args: argparse.Namespace,
    payload: dict[str, Any],
) -> tuple[Path, Optional[Path]]:
    input_path = args.input
    snapshot_path = derive_snapshot_path(input_path, payload, args.snapshot)
    return input_path, snapshot_path


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Print false-positive and false-negative reply-queue chats with side-by-side ownership evidence."
    )
    parser.add_argument("--gold", type=Path, default=DEFAULT_GOLD_PATH, help="Gold label JSON file.")
    parser.add_argument(
        "--input",
        type=Path,
        required=True,
        help="Saved benchmark result JSON or candidate snapshot JSON.",
    )
    parser.add_argument(
        "--snapshot",
        type=Path,
        help="Optional candidate snapshot JSON to enrich a benchmark result file.",
    )
    parser.add_argument("--limit", type=int, default=999, help="Max diff entries to print per section.")
    args = parser.parse_args()

    gold = load_gold(args.gold)
    input_payload = load_json(args.input)
    input_path, snapshot_path = resolve_input_paths(args, input_payload)

    predictions = extract_result_predictions(input_payload)
    predicted_on_me = {chat_id for chat_id, prediction in predictions.items() if prediction.classification == "on_me"}

    candidate_source_path = snapshot_path if snapshot_path else input_path
    candidates = load_candidate_snapshot(candidate_source_path)

    gold_positive = {chat_id for chat_id, label in gold.items() if label.label == "on_me"}
    fp_ids = sort_diff_ids(predicted_on_me - gold_positive, gold, candidates)[: args.limit]
    fn_ids = sort_diff_ids(gold_positive - predicted_on_me, gold, candidates)[: args.limit]

    counts = summarize_counts(gold, predicted_on_me)
    print(f"input: {input_path}")
    print(f"candidate_source: {candidate_source_path}")
    print(
        "counts: "
        f"gold_on_me={counts['gold_on_me']} "
        f"gold_maybe={counts['gold_maybe']} "
        f"predicted_on_me={counts['predicted_on_me']} "
        f"fp_strict={counts['fp_strict']} "
        f"fn_strict={counts['fn_strict']} "
        f"fp_lenient={counts['fp_lenient']} "
        f"fn_lenient={counts['fn_lenient']}"
    )
    print(f"prediction_source: {'benchmark_result' if 'results' in input_payload else 'snapshot_selection'}")
    print()

    print("FALSE POSITIVES")
    if fp_ids:
        for chat_id in fp_ids:
            print(render_entry("FP", chat_id, gold, predictions, candidates))
            print()
    else:
        print("  none\n")

    print("FALSE NEGATIVES")
    if fn_ids:
        for chat_id in fn_ids:
            print(render_entry("FN", chat_id, gold, predictions, candidates))
            print()
    else:
        print("  none\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
