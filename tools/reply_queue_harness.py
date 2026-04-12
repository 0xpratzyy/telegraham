#!/usr/bin/env python3
import argparse
import json
import math
import statistics
import time
from pathlib import Path
from typing import Any, Optional

from reply_queue_gold_eval import GoldLabel, evaluate, load_gold
from reply_queue_variant_bench import (
    APP_SUPPORT,
    DEFAULT_API_KEY_PATH,
    DEFAULT_SNAPSHOT_PATH,
    VARIANT_PACKS,
    VARIANT_RUNS,
    VariantRun,
    load_api_key,
    run_variant,
)


DEFAULT_OUT_DIR = APP_SUPPORT / "debug" / "reply_queue_harness"


def variant_map() -> dict[str, VariantRun]:
    return {variant.name: variant for variant in VARIANT_RUNS}


def average_pairwise_jaccard(trials: list[dict[str, Any]]) -> float:
    sets = [set(int(chat_id) for chat_id in trial.get("on_me_chat_ids", [])) for trial in trials]
    if len(sets) < 2:
        return 1.0

    scores: list[float] = []
    for left_index in range(len(sets)):
        for right_index in range(left_index + 1, len(sets)):
            left = sets[left_index]
            right = sets[right_index]
            if not left and not right:
                scores.append(1.0)
                continue
            union = left | right
            scores.append(len(left & right) / len(union) if union else 1.0)
    return average(scores)


def pick_variants(names: list[str], packs: Optional[list[str]] = None) -> list[VariantRun]:
    available = variant_map()
    requested_names = [name for name in (names or []) if name != "all"]

    for pack in packs or []:
        pack_variants = VARIANT_PACKS.get(pack)
        if pack_variants is None:
            available_packs = ", ".join(sorted(VARIANT_PACKS))
            raise SystemExit(f"Unknown pack: {pack}\nAvailable packs: {available_packs}")
        requested_names.extend(pack_variants)

    if not requested_names or requested_names == ["all"]:
        return VARIANT_RUNS

    picked: list[VariantRun] = []
    missing: list[str] = []
    seen: set[str] = set()
    for name in requested_names:
        if name in seen:
            continue
        seen.add(name)
        variant = available.get(name)
        if variant is None:
            missing.append(name)
            continue
        picked.append(variant)

    if missing:
        available_names = ", ".join(sorted(available))
        raise SystemExit(
            f"Unknown variants: {', '.join(missing)}\nAvailable: {available_names}"
        )
    return picked


def average(values: list[float]) -> float:
    return sum(values) / len(values) if values else 0.0


def metric_value(report: dict[str, Any], path: str) -> float:
    node: Any = report
    for part in path.split("."):
        node = node[part]
    return float(node)


def label_name(chat_id: int, labels: dict[int, GoldLabel]) -> str:
    label = labels.get(chat_id)
    if not label:
        return str(chat_id)
    return f"{label.chat_name} ({label.label})"


def sort_ids(ids: set[int], labels: dict[int, GoldLabel]) -> list[int]:
    return sorted(ids, key=lambda chat_id: (labels.get(chat_id).chat_name.lower() if labels.get(chat_id) else str(chat_id)))


def summarize_variant(
    variant: VariantRun,
    trials: list[dict[str, Any]],
    reports: list[dict[str, Any]],
    labels: dict[int, GoldLabel],
) -> dict[str, Any]:
    wall_clock_ms = [int(trial["wall_clock_ms"]) for trial in trials]
    standard_costs = [float(trial["estimated_standard_cost_usd"] or 0.0) for trial in trials]

    vote_counts: dict[int, int] = {}
    for trial in trials:
        for chat_id in trial.get("on_me_chat_ids", []):
            vote_counts[int(chat_id)] = vote_counts.get(int(chat_id), 0) + 1

    majority_threshold = math.ceil(len(trials) / 2)
    stable_on_me = {chat_id for chat_id, count in vote_counts.items() if count == len(trials)}
    majority_on_me = {chat_id for chat_id, count in vote_counts.items() if count >= majority_threshold}

    majority_report = evaluate(f"{variant.name}_majority_vote", majority_on_me, labels)
    best_trial_index = max(
        range(len(reports)),
        key=lambda index: (
            metric_value(reports[index], "overall_strict.f1"),
            metric_value(reports[index], "groups_lenient.f1"),
            -int(trials[index]["wall_clock_ms"]),
        ),
    )

    strict_f1s = [metric_value(report, "overall_strict.f1") for report in reports]
    lenient_f1s = [metric_value(report, "overall_lenient.f1") for report in reports]
    group_lenient_f1s = [metric_value(report, "groups_lenient.f1") for report in reports]
    strict_precisions = [metric_value(report, "overall_strict.precision") for report in reports]
    strict_recalls = [metric_value(report, "overall_strict.recall") for report in reports]
    group_fp_counts = [len(report["groups_lenient"]["fp_ids"]) for report in reports]
    group_fn_counts = [len(report["groups_lenient"]["fn_ids"]) for report in reports]

    return {
        "name": variant.name,
        "prompt_variant": variant.prompt_variant,
        "payload_variant": variant.payload_variant,
        "trial_count": len(trials),
        "latency": {
            "min_ms": min(wall_clock_ms),
            "median_ms": int(statistics.median(wall_clock_ms)),
            "max_ms": max(wall_clock_ms),
            "mean_ms": average([float(value) for value in wall_clock_ms]),
        },
        "cost": {
            "mean_standard_usd": average(standard_costs),
            "max_standard_usd": max(standard_costs),
        },
        "metrics": {
            "avg_overall_strict_f1": average(strict_f1s),
            "avg_overall_lenient_f1": average(lenient_f1s),
            "avg_group_lenient_f1": average(group_lenient_f1s),
            "median_overall_strict_f1": float(statistics.median(strict_f1s)),
            "min_overall_strict_f1": min(strict_f1s),
            "median_overall_lenient_f1": float(statistics.median(lenient_f1s)),
            "median_group_lenient_f1": float(statistics.median(group_lenient_f1s)),
            "avg_overall_strict_precision": average(strict_precisions),
            "avg_overall_strict_recall": average(strict_recalls),
            "avg_group_false_positive_count": average([float(count) for count in group_fp_counts]),
            "max_group_false_positive_count": max(group_fp_counts),
            "avg_group_miss_count": average([float(count) for count in group_fn_counts]),
            "majority_vote": majority_report,
        },
        "stability": {
            "average_pairwise_jaccard": average_pairwise_jaccard(trials),
            "stable_on_me_chat_ids": sort_ids(stable_on_me, labels),
            "majority_on_me_chat_ids": sort_ids(majority_on_me, labels),
            "chat_vote_rates": [
                {
                    "chatId": chat_id,
                    "chatName": labels.get(chat_id).chat_name if labels.get(chat_id) else str(chat_id),
                    "label": labels.get(chat_id).label if labels.get(chat_id) else "unknown",
                    "votes": count,
                    "voteRate": count / len(trials),
                }
                for chat_id, count in sorted(vote_counts.items(), key=lambda item: (-item[1], label_name(item[0], labels).lower()))
            ],
        },
        "winner_trial": {
            "trial_index": best_trial_index + 1,
            "wall_clock_ms": trials[best_trial_index]["wall_clock_ms"],
            "estimated_standard_cost_usd": trials[best_trial_index]["estimated_standard_cost_usd"],
            "report": reports[best_trial_index],
        },
        "group_false_positives_majority": [
            label_name(chat_id, labels)
            for chat_id in majority_report["groups_lenient"]["fp_ids"]
        ],
        "group_misses_majority": [
            label_name(chat_id, labels)
            for chat_id in majority_report["groups_lenient"]["fn_ids"]
        ],
    }


def leaderboard_rows(aggregates: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return sorted(
        aggregates,
        key=lambda item: (
            -item["metrics"]["median_overall_strict_f1"],
            -item["metrics"]["min_overall_strict_f1"],
            -item["stability"]["average_pairwise_jaccard"],
            -item["metrics"]["majority_vote"]["overall_strict"]["f1"],
            -item["metrics"]["majority_vote"]["groups_lenient"]["f1"],
            item["metrics"]["max_group_false_positive_count"],
            item["latency"]["median_ms"],
        ),
    )


def render_markdown(
    snapshot_path: Path,
    variants: list[VariantRun],
    aggregates: list[dict[str, Any]],
) -> str:
    lines = [
        "# Reply Queue Harness Report",
        "",
        f"Snapshot: `{snapshot_path}`",
        f"Variants: `{', '.join(variant.name for variant in variants)}`",
        "",
        "| Variant | Trials | Median ms | Median strict F1 | Min strict F1 | Group lenient F1 | Avg Jaccard | Mean cost | Stable on_me |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]

    for item in leaderboard_rows(aggregates):
        lines.append(
            "| "
            + f"{item['name']} | "
            + f"{item['trial_count']} | "
            + f"{item['latency']['median_ms']} | "
            + f"{item['metrics']['median_overall_strict_f1']:.2f} | "
            + f"{item['metrics']['min_overall_strict_f1']:.2f} | "
            + f"{item['metrics']['majority_vote']['groups_lenient']['f1']:.2f} | "
            + f"{item['stability']['average_pairwise_jaccard']:.2f} | "
            + f"${item['cost']['mean_standard_usd']:.4f} | "
            + f"{len(item['stability']['stable_on_me_chat_ids'])} |"
        )

    best = leaderboard_rows(aggregates)[0]
    lines.extend(
        [
            "",
            "## Current Winner",
            "",
            f"- Variant: `{best['name']}`",
            f"- Median latency: `{best['latency']['median_ms']}ms`",
            f"- Median strict F1: `{best['metrics']['median_overall_strict_f1']:.2f}`",
            f"- Min strict F1: `{best['metrics']['min_overall_strict_f1']:.2f}`",
            f"- Group lenient F1: `{best['metrics']['majority_vote']['groups_lenient']['f1']:.2f}`",
            f"- Average pairwise Jaccard: `{best['stability']['average_pairwise_jaccard']:.2f}`",
            f"- Group false positives: `{', '.join(best['group_false_positives_majority']) or 'none'}`",
            f"- Group misses: `{', '.join(best['group_misses_majority']) or 'none'}`",
        ]
    )
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run repeated reply-queue prompt/digest benchmarks and score them against the manual gold set."
    )
    parser.add_argument("--snapshot", type=Path, default=DEFAULT_SNAPSHOT_PATH)
    parser.add_argument("--gold", type=Path, default=Path("/Users/pratyushrungta/telegraham/evals/reply_queue_manual_gold_mixed_recent_48.json"))
    parser.add_argument("--api-key-file", type=Path, default=DEFAULT_API_KEY_PATH)
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    parser.add_argument("--variants", nargs="*", default=["all"])
    parser.add_argument("--packs", nargs="*", default=[])
    parser.add_argument("--trials", type=int, default=1)
    parser.add_argument("--batch-size", type=int, default=12)
    args = parser.parse_args()

    if args.trials < 1:
        raise SystemExit("--trials must be >= 1")
    if not args.snapshot.exists():
        raise SystemExit(f"Snapshot not found: {args.snapshot}")

    variants = pick_variants(args.variants, args.packs)
    snapshot = json.loads(args.snapshot.read_text())
    labels = load_gold(args.gold)
    api_key = load_api_key(args.api_key_file)

    run_id = time.strftime("%Y%m%d-%H%M%S", time.gmtime())
    out_dir = args.out_dir / run_id
    trials_dir = out_dir / "trials"
    trials_dir.mkdir(parents=True, exist_ok=True)

    aggregates: list[dict[str, Any]] = []
    for variant in variants:
        variant_trials: list[dict[str, Any]] = []
        variant_reports: list[dict[str, Any]] = []
        variant_trial_dir = trials_dir / variant.name
        variant_trial_dir.mkdir(parents=True, exist_ok=True)

        for trial_index in range(1, args.trials + 1):
            print(f"Running {variant.name} trial {trial_index}/{args.trials}...", flush=True)
            payload = run_variant(api_key, snapshot, variant, args.batch_size)
            payload["capturedAt"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            payload["snapshotQuery"] = snapshot["query"]
            payload["snapshotScope"] = snapshot["scope"]
            payload["snapshotStrategy"] = snapshot.get("strategy")

            predicted = {int(chat_id) for chat_id in payload.get("on_me_chat_ids", [])}
            report = evaluate(f"{variant.name}_trial_{trial_index}", predicted, labels)
            payload["evaluation"] = report

            trial_path = variant_trial_dir / f"trial_{trial_index:02d}.json"
            trial_path.write_text(json.dumps(payload, indent=2, sort_keys=True))

            variant_trials.append(payload)
            variant_reports.append(report)

        aggregates.append(summarize_variant(variant, variant_trials, variant_reports, labels))

    leaderboard = leaderboard_rows(aggregates)
    report_payload = {
        "capturedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "snapshot": str(args.snapshot),
        "gold": str(args.gold),
        "variants": [variant.name for variant in variants],
        "trials": args.trials,
        "batchSize": args.batch_size,
        "leaderboard": leaderboard,
    }

    report_json = out_dir / "report.json"
    report_md = out_dir / "leaderboard.md"
    report_json.write_text(json.dumps(report_payload, indent=2, sort_keys=True))
    report_md.write_text(render_markdown(args.snapshot, variants, aggregates))

    winner = leaderboard[0]
    print(
        json.dumps(
            {
                "runId": run_id,
                "winner": winner["name"],
                "winnerMedianMs": winner["latency"]["median_ms"],
                "winnerStrictF1": winner["metrics"]["majority_vote"]["overall_strict"]["f1"],
                "winnerGroupLenientF1": winner["metrics"]["majority_vote"]["groups_lenient"]["f1"],
                "reportJson": str(report_json),
                "reportMarkdown": str(report_md),
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
