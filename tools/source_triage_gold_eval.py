#!/usr/bin/env python3
"""Score live Pidgy triage/task projections against private source gold.

The fixture intentionally stores source locators and adjudicated labels, not
raw email or chat bodies. Gmail messages resolve through messages.external_id.
Slack messages resolve through id_map's native ``msg:<channel>:<ts>`` key,
which also works for legacy Slack rows whose provenance columns are empty.

Missing source rows predict ``ignore`` for end-to-end scoring: filtering a
known-noise message is correct, while failing to ingest an actionable message
is a false negative. Ingestion coverage is reported separately so a high noise
score cannot hide a stale connector.
"""

from __future__ import annotations

import argparse
import json
import sqlite3
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


LABELS = ("ignore", "reply", "task", "waiting")
SCORABLE_REVIEW_STATES = {"approved"}


@dataclass(frozen=True)
class ResolvedMessage:
    message_id: int
    chat_id: int
    ingested: bool = True


def load_fixture(path: Path, include_provisional: bool = False) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    payload = json.loads(path.read_text())
    if payload.get("schemaVersion") != 1:
        raise ValueError("fixture schemaVersion must be 1")
    cases = payload.get("cases")
    if not isinstance(cases, list) or not cases:
        raise ValueError("fixture must contain a non-empty cases array")

    seen: set[str] = set()
    selected: list[dict[str, Any]] = []
    allowed_reviews = SCORABLE_REVIEW_STATES | ({"provisional"} if include_provisional else set())
    for case in cases:
        case_id = case.get("id")
        if not isinstance(case_id, str) or not case_id:
            raise ValueError("every case needs a non-empty id")
        if case_id in seen:
            raise ValueError(f"duplicate case id: {case_id}")
        seen.add(case_id)

        source = case.get("source")
        if source not in {"gmail", "slack"}:
            raise ValueError(f"{case_id}: source must be gmail or slack")
        label = case.get("gold", {}).get("label")
        if label not in LABELS:
            raise ValueError(f"{case_id}: gold.label must be one of {LABELS}")
        if not case.get("message", {}).get("externalId"):
            raise ValueError(f"{case_id}: message.externalId is required")
        if source == "slack" and not case.get("message", {}).get("conversationExternalId"):
            raise ValueError(f"{case_id}: Slack cases need message.conversationExternalId")

        review_state = case.get("review", {}).get("status", "provisional")
        if review_state in allowed_reviews:
            selected.append(case)

    if not selected:
        raise ValueError("fixture has no scorable cases; approve cases or use --include-provisional")
    return payload, selected


def resolve_message(db: sqlite3.Connection, case: dict[str, Any]) -> ResolvedMessage | None:
    source = case["source"]
    account = case.get("account", "")
    locator = case["message"]
    external_id = str(locator["externalId"])

    if source == "gmail":
        source_id = f"gmail:{account}" if account else "gmail:%"
        operator = "=" if account else "LIKE"
        row = db.execute(
            f"""
            SELECT id, chat_id
            FROM messages
            WHERE source {operator} ? AND external_id = ?
            ORDER BY date DESC
            LIMIT 1
            """,
            (source_id, external_id),
        ).fetchone()
    else:
        source_id = f"slack:{account}" if account else "slack:%"
        operator = "=" if account else "LIKE"
        native_id = f"msg:{locator['conversationExternalId']}:{external_id}"
        row = db.execute(
            f"""
            SELECT m.id, m.chat_id
            FROM id_map im
            JOIN messages m ON m.id = im.int_id AND m.source = im.source
            WHERE im.source {operator} ? AND im.native_id = ?
            ORDER BY m.date DESC
            LIMIT 1
            """,
            (source_id, native_id),
        ).fetchone()

    if row is None:
        return None
    return ResolvedMessage(message_id=int(row[0]), chat_id=int(row[1]))


def classify_facts(rows: Iterable[sqlite3.Row]) -> tuple[str, list[dict[str, Any]]]:
    facts = [dict(row) for row in rows]
    labels: set[str] = set()
    for fact in facts:
        predicate = fact.get("predicate")
        kind = fact.get("loop_kind")
        if predicate == "i_owe" and kind == "action":
            labels.add("task")
        elif predicate == "i_owe":
            labels.add("reply")
        elif predicate == "owes_me":
            labels.add("waiting")

    # A concrete task outranks a reply, which outranks a waiting item. Multiple
    # labels remain visible in the JSON evidence for collision diagnosis.
    for label in ("task", "reply", "waiting"):
        if label in labels:
            return label, facts
    return "ignore", facts


def prediction_for_case(db: sqlite3.Connection, case: dict[str, Any]) -> dict[str, Any]:
    resolved = resolve_message(db, case)
    if resolved is None:
        return {"label": "ignore", "ingested": False, "facts": []}

    rows = db.execute(
        """
        SELECT id, predicate, loop_kind, action, subject_entity, valid_from
        FROM facts
        WHERE source_chat_id = ? AND source_message_id = ? AND invalid_at IS NULL
        ORDER BY confidence DESC, id ASC
        """,
        (resolved.chat_id, resolved.message_id),
    ).fetchall()
    label, facts = classify_facts(rows)
    return {
        "label": label,
        "ingested": True,
        "messageId": resolved.message_id,
        "chatId": resolved.chat_id,
        "facts": facts,
    }


def ratio(numerator: int, denominator: int) -> float:
    return numerator / denominator if denominator else 0.0


def prf(tp: int, fp: int, fn: int) -> dict[str, Any]:
    precision = ratio(tp, tp + fp)
    recall = ratio(tp, tp + fn)
    f1 = ratio(2 * precision * recall, precision + recall)
    return {"tp": tp, "fp": fp, "fn": fn, "precision": precision, "recall": recall, "f1": f1}


def evaluate(
    db: sqlite3.Connection,
    cases: list[dict[str, Any]],
    include_source_breakdown: bool = True,
) -> dict[str, Any]:
    db.row_factory = sqlite3.Row
    results: list[dict[str, Any]] = []
    confusion: Counter[tuple[str, str]] = Counter()
    for case in cases:
        predicted = prediction_for_case(db, case)
        gold = case["gold"]["label"]
        confusion[(gold, predicted["label"])] += 1
        results.append(
            {
                "id": case["id"],
                "source": case["source"],
                "gold": gold,
                "predicted": predicted["label"],
                "correct": gold == predicted["label"],
                **{key: value for key, value in predicted.items() if key != "label"},
            }
        )

    per_label: dict[str, Any] = {}
    for label in LABELS:
        tp = confusion[(label, label)]
        fp = sum(count for (gold, predicted), count in confusion.items() if predicted == label and gold != label)
        fn = sum(count for (gold, predicted), count in confusion.items() if gold == label and predicted != label)
        support = sum(count for (gold, _), count in confusion.items() if gold == label)
        per_label[label] = {**prf(tp, fp, fn), "support": support}

    positive_labels = {"reply", "task", "waiting"}
    tp = sum(count for (gold, predicted), count in confusion.items() if gold in positive_labels and predicted in positive_labels)
    fp = sum(count for (gold, predicted), count in confusion.items() if gold == "ignore" and predicted in positive_labels)
    fn = sum(count for (gold, predicted), count in confusion.items() if gold in positive_labels and predicted == "ignore")
    correct = sum(1 for result in results if result["correct"])
    ingested = sum(1 for result in results if result["ingested"])

    present_labels = [label for label in LABELS if per_label[label]["support"] > 0]
    report = {
        "cases": len(results),
        "accuracy": ratio(correct, len(results)),
        "ingestionCoverage": ratio(ingested, len(results)),
        "actionable": prf(tp, fp, fn),
        "macroF1": sum(per_label[label]["f1"] for label in LABELS) / len(LABELS),
        "macroF1PresentLabels": ratio(
            sum(per_label[label]["f1"] for label in present_labels),
            len(present_labels),
        ),
        "perLabel": per_label,
        "confusion": {
            gold: {predicted: confusion[(gold, predicted)] for predicted in LABELS}
            for gold in LABELS
        },
        "results": results,
    }
    if include_source_breakdown:
        report["bySource"] = {
            source: evaluate(
                db,
                [case for case in cases if case["source"] == source],
                include_source_breakdown=False,
            )
            for source in sorted({case["source"] for case in cases})
        }
    return report


def print_report(name: str, report: dict[str, Any]) -> None:
    print(f"\n=== {name} ===")
    print(
        f"cases={report['cases']} accuracy={report['accuracy']:.1%} "
        f"macro_f1_present={report['macroF1PresentLabels']:.1%} "
        f"ingestion={report['ingestionCoverage']:.1%}"
    )
    actionable = report["actionable"]
    print(
        "actionable: "
        f"P={actionable['precision']:.1%} R={actionable['recall']:.1%} "
        f"F1={actionable['f1']:.1%} "
        f"(tp={actionable['tp']} fp={actionable['fp']} fn={actionable['fn']})"
    )
    for label in LABELS:
        metric = report["perLabel"][label]
        print(
            f"{label:7} P={metric['precision']:.1%} R={metric['recall']:.1%} "
            f"F1={metric['f1']:.1%} support={metric['support']}"
        )

    for source, source_report in report.get("bySource", {}).items():
        source_actionable = source_report["actionable"]
        print(
            f"{source}: accuracy={source_report['accuracy']:.1%} "
            f"actionable_f1={source_actionable['f1']:.1%} "
            f"ingestion={source_report['ingestionCoverage']:.1%}"
        )

    failures = [result for result in report["results"] if not result["correct"]]
    print("failures:")
    if not failures:
        print("  - none")
    for result in failures:
        suffix = "not ingested" if not result["ingested"] else f"{len(result['facts'])} open fact(s)"
        print(f"  - {result['id']}: gold={result['gold']} predicted={result['predicted']} ({suffix})")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gold", type=Path, required=True, help="Private or sanitized gold JSON")
    parser.add_argument("--db", type=Path, default=Path.home() / "Library/Application Support/Pidgy/pidgy.db")
    parser.add_argument("--include-provisional", action="store_true", help="Score provisional cases as a silver audit")
    parser.add_argument("--out", type=Path, help="Optional detailed JSON report")
    args = parser.parse_args()

    payload, cases = load_fixture(args.gold, include_provisional=args.include_provisional)
    with sqlite3.connect(args.db) as db:
        report = evaluate(db, cases)
    print_report(payload.get("name", args.gold.stem), report)

    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps({"fixture": payload.get("name"), **report}, indent=2))
        print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
