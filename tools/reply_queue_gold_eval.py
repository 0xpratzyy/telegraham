#!/usr/bin/env python3
import argparse
import glob
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional


DEFAULT_GOLD_PATH = Path("/Users/pratyushrungta/telegraham/evals/reply_queue_manual_gold_mixed_recent_48.json")


@dataclass
class GoldLabel:
    chat_id: int
    chat_name: str
    chat_type: str
    label: str
    reason: str


def normalize_label(label: str) -> str:
    compact = (label or "").strip()
    if compact == "maybe":
        return "worth_checking"
    return compact


def load_gold(path: Path) -> dict[int, GoldLabel]:
    payload = json.loads(path.read_text())
    labels: dict[int, GoldLabel] = {}
    for chat_id, item in payload["labels"].items():
        labels[int(chat_id)] = GoldLabel(
            chat_id=int(chat_id),
            chat_name=item["chatName"],
            chat_type=item["chatType"],
            label=normalize_label(item["label"]),
            reason=item["reason"],
        )
    return labels


def extract_prediction_sets(payload: dict[str, Any]) -> dict[str, set[int]]:
    on_me_ids: set[int] = set()
    worth_checking_ids: set[int] = set()

    if "results" in payload and isinstance(payload["results"], list):
        first = payload["results"][0] if payload["results"] else None
        if isinstance(first, dict) and "on_me_chat_ids" in first:
            for result in payload["results"]:
                on_me_ids.update(int(chat_id) for chat_id in result.get("on_me_chat_ids", []))
                worth_checking_ids.update(int(chat_id) for chat_id in result.get("worth_checking_chat_ids", []))
            return {
                "on_me": on_me_ids,
                "worth_checking": worth_checking_ids,
                "surfaced": on_me_ids | worth_checking_ids,
            }

        for result in payload["results"]:
            if not isinstance(result, dict) or "chatId" not in result:
                continue
            chat_id = int(result["chatId"])
            classification = result.get("classification")
            if classification == "on_me":
                on_me_ids.add(chat_id)
            elif classification == "worth_checking":
                worth_checking_ids.add(chat_id)
        if on_me_ids or worth_checking_ids:
            return {
                "on_me": on_me_ids,
                "worth_checking": worth_checking_ids,
                "surfaced": on_me_ids | worth_checking_ids,
            }

    output = payload.get("output")
    if isinstance(output, dict):
        return extract_prediction_sets(output)

    batches = payload.get("batches")
    if isinstance(batches, list):
        for batch in batches:
            on_me_ids.update(int(chat_id) for chat_id in batch.get("on_me_chat_ids", []))
            worth_checking_ids.update(int(chat_id) for chat_id in batch.get("worth_checking_chat_ids", []))

    return {
        "on_me": on_me_ids,
        "worth_checking": worth_checking_ids,
        "surfaced": on_me_ids | worth_checking_ids,
    }


def extract_on_me_chat_ids(payload: dict[str, Any]) -> set[int]:
    return extract_prediction_sets(payload)["on_me"]


def precision(tp: int, fp: int) -> float:
    return tp / (tp + fp) if (tp + fp) else 0.0


def recall(tp: int, fn: int) -> float:
    return tp / (tp + fn) if (tp + fn) else 0.0


def f1(p: float, r: float) -> float:
    return (2 * p * r / (p + r)) if (p + r) else 0.0


def metric_block(
    predicted: set[int],
    labels: dict[int, GoldLabel],
    group_only: bool,
    positive_labels: set[str],
) -> dict[str, Any]:
    scope_labels = {
        chat_id: label
        for chat_id, label in labels.items()
        if (not group_only or label.chat_type == "group")
    }

    positives = {chat_id for chat_id, label in scope_labels.items() if label.label in positive_labels}
    predicted_scoped = {chat_id for chat_id in predicted if chat_id in scope_labels}

    tp_ids = predicted_scoped & positives
    fp_ids = predicted_scoped - positives
    fn_ids = positives - predicted_scoped

    return {
        "tp": len(tp_ids),
        "fp": len(fp_ids),
        "fn": len(fn_ids),
        "precision": precision(len(tp_ids), len(fp_ids)),
        "recall": recall(len(tp_ids), len(fn_ids)),
        "f1": f1(precision(len(tp_ids), len(fp_ids)), recall(len(tp_ids), len(fn_ids))),
        "tp_ids": sorted(tp_ids),
        "fp_ids": sorted(fp_ids),
        "fn_ids": sorted(fn_ids),
    }


def label_name(chat_id: int, labels: dict[int, GoldLabel]) -> str:
    label = labels.get(chat_id)
    if not label:
        return str(chat_id)
    return f"{label.chat_name} ({label.label})"


def evaluate(
    name: str,
    predicted_on_me: set[int],
    labels: dict[int, GoldLabel],
    predicted_surfaced: Optional[set[int]] = None,
    predicted_worth_checking: Optional[set[int]] = None,
) -> dict[str, Any]:
    surfaced = predicted_surfaced if predicted_surfaced is not None else set(predicted_on_me)
    worth_checking = predicted_worth_checking if predicted_worth_checking is not None else set()
    return {
        "name": name,
        "predicted_on_me": sorted(predicted_on_me),
        "predicted_surfaced": sorted(surfaced),
        "predicted_worth_checking": sorted(worth_checking),
        "overall_strict": metric_block(predicted_on_me, labels, group_only=False, positive_labels={"on_me"}),
        "overall_lenient": metric_block(surfaced, labels, group_only=False, positive_labels={"on_me", "worth_checking"}),
        "groups_strict": metric_block(predicted_on_me, labels, group_only=True, positive_labels={"on_me"}),
        "groups_lenient": metric_block(surfaced, labels, group_only=True, positive_labels={"on_me", "worth_checking"}),
        "worth_checking_only": metric_block(worth_checking, labels, group_only=False, positive_labels={"worth_checking"}),
        "groups_worth_checking_only": metric_block(worth_checking, labels, group_only=True, positive_labels={"worth_checking"}),
    }


def print_report(report: dict[str, Any], labels: dict[int, GoldLabel]) -> None:
    print(f"\n=== {report['name']} ===")
    for key in ("overall_strict", "overall_lenient", "groups_strict", "groups_lenient", "worth_checking_only", "groups_worth_checking_only"):
        block = report[key]
        print(
            f"{key}: "
            f"P={block['precision']:.2f} "
            f"R={block['recall']:.2f} "
            f"F1={block['f1']:.2f} "
            f"(tp={block['tp']}, fp={block['fp']}, fn={block['fn']})"
        )

    fp_names = [label_name(chat_id, labels) for chat_id in report["groups_strict"]["fp_ids"]]
    fn_names = [label_name(chat_id, labels) for chat_id in report["groups_lenient"]["fn_ids"]]

    print("group false positives:")
    if fp_names:
        for name in fp_names:
            print(f"  - {name}")
    else:
        print("  - none")

    print("group misses (lenient):")
    if fn_names:
        for name in fn_names:
            print(f"  - {name}")
    else:
        print("  - none")


def main() -> int:
    parser = argparse.ArgumentParser(description="Evaluate saved reply-queue results against manual gold labels.")
    parser.add_argument("--gold", type=Path, default=DEFAULT_GOLD_PATH)
    parser.add_argument("--results", nargs="*", help="One or more result files or glob patterns.")
    parser.add_argument("--out", type=Path, help="Optional JSON report output path.")
    args = parser.parse_args()

    labels = load_gold(args.gold)

    patterns = args.results or [
        str(Path.home() / "Library/Application Support/Pidgy/debug/quality_compare/mini_4x12_part*.json"),
        str(Path.home() / "Library/Application Support/Pidgy/debug/quality_compare/nano_4x12_part*.json"),
        str(Path.home() / "Library/Application Support/Pidgy/debug/quality_compare/o4mini_4x12_part*.json"),
    ]

    grouped_files: dict[str, list[Path]] = {}
    for pattern in patterns:
        matches = [Path(match) for match in glob.glob(pattern)]
        if not matches:
            continue

        if len(matches) == 1:
            grouped_files[matches[0].stem] = matches
            continue

        prefix = matches[0].name.split("_part")[0]
        grouped_files[prefix] = sorted(matches)

    reports: list[dict[str, Any]] = []
    for name, files in sorted(grouped_files.items()):
        predicted_on_me: set[int] = set()
        predicted_surfaced: set[int] = set()
        predicted_worth_checking: set[int] = set()
        for file_path in files:
            payload = json.loads(file_path.read_text())
            prediction_sets = extract_prediction_sets(payload)
            predicted_on_me.update(prediction_sets["on_me"])
            predicted_surfaced.update(prediction_sets["surfaced"])
            predicted_worth_checking.update(prediction_sets["worth_checking"])

        report = evaluate(
            name,
            predicted_on_me,
            labels,
            predicted_surfaced=predicted_surfaced,
            predicted_worth_checking=predicted_worth_checking,
        )
        reports.append(report)
        print_report(report, labels)

    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps({"reports": reports}, indent=2))
        print(f"\nwrote {args.out}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
