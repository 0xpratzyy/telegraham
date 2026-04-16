#!/usr/bin/env python3
import argparse
import json
import time
from pathlib import Path
from typing import Any

from reply_queue_gold_eval import evaluate, extract_prediction_sets, load_gold
from reply_queue_harness import leaderboard_rows, summarize_variant
from reply_queue_variant_bench import DEFAULT_API_KEY_PATH, VARIANT_RUNS, load_api_key, run_variant


DEFAULT_ORACLE = Path("/Users/pratyushrungta/telegraham/evals/reply_queue_manual_oracle_v1.json")
DEFAULT_OUT_DIR = Path.home() / "Library" / "Application Support" / "Pidgy" / "debug" / "reply_queue_oracle_bench"


def load_oracle(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text())


def aggregate_snapshot_metrics(snapshot_rows: list[dict[str, Any]]) -> dict[str, Any]:
    if not snapshot_rows:
        return {
            "snapshotCount": 0,
            "avgOverallStrictF1": 0.0,
            "minOverallStrictF1": 0.0,
            "avgOverallLenientF1": 0.0,
            "avgGroupLenientF1": 0.0,
        }
    return {
        "snapshotCount": len(snapshot_rows),
        "avgOverallStrictF1": sum(row["overall_strict"]["f1"] for row in snapshot_rows) / len(snapshot_rows),
        "minOverallStrictF1": min(row["overall_strict"]["f1"] for row in snapshot_rows),
        "avgOverallLenientF1": sum(row["overall_lenient"]["f1"] for row in snapshot_rows) / len(snapshot_rows),
        "avgGroupLenientF1": sum(row["groups_lenient"]["f1"] for row in snapshot_rows) / len(snapshot_rows),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Run reply-queue variants against the assistant-authored multi-snapshot oracle.")
    parser.add_argument("--oracle", type=Path, default=DEFAULT_ORACLE)
    parser.add_argument("--variants", nargs="*", default=[
        "baseline_compact_v1_4x12",
        "field_aware_groups_v3_digest_v4_digest_v4_4x12",
        "field_aware_groups_v3_private_recall_v2_digest_v5_digest_v5_4x12"
    ])
    parser.add_argument("--trials", type=int, default=1)
    parser.add_argument("--batch-size", type=int, default=12)
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    parser.add_argument("--api-key-file", type=Path, default=DEFAULT_API_KEY_PATH)
    args = parser.parse_args()

    oracle = load_oracle(args.oracle)
    labels = load_gold(args.oracle)
    snapshots = [Path(path) for path in oracle["snapshots"]]
    variants_by_name = {variant.name: variant for variant in VARIANT_RUNS}
    variants = [variants_by_name[name] for name in args.variants]
    api_key = load_api_key(args.api_key_file)

    aggregates: list[dict[str, Any]] = []
    by_variant: dict[str, Any] = {}

    for variant in variants:
        variant_trials: list[dict[str, Any]] = []
        variant_reports: list[dict[str, Any]] = []
        per_snapshot_rows: list[dict[str, Any]] = []

        for snapshot_path in snapshots:
            snapshot = json.loads(snapshot_path.read_text())
            for trial_index in range(args.trials):
                payload = run_variant(api_key, snapshot, variant, args.batch_size)
                prediction_sets = extract_prediction_sets(payload)
                report = evaluate(
                    f"{variant.name}:{snapshot_path.name}:trial_{trial_index+1}",
                    prediction_sets["on_me"],
                    labels,
                    predicted_surfaced=prediction_sets["surfaced"],
                    predicted_worth_checking=prediction_sets["worth_checking"],
                )
                payload["evaluation"] = report
                payload["snapshotPath"] = str(snapshot_path)
                payload["trialIndex"] = trial_index + 1
                variant_trials.append(payload)
                variant_reports.append(report)
                per_snapshot_rows.append({
                    "snapshot": snapshot_path.name,
                    "overall_strict": report["overall_strict"],
                    "overall_lenient": report["overall_lenient"],
                    "groups_lenient": report["groups_lenient"],
                })

        summary = summarize_variant(variant, variant_trials, variant_reports, labels)
        summary["oracleSummary"] = aggregate_snapshot_metrics(per_snapshot_rows)
        summary["perSnapshot"] = per_snapshot_rows
        aggregates.append(summary)
        by_variant[variant.name] = {
            "summary": summary,
            "trials": variant_trials,
        }

    leaderboard = leaderboard_rows(aggregates)
    report = {
        "capturedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "oracle": str(args.oracle),
        "snapshots": [str(path) for path in snapshots],
        "variants": args.variants,
        "trials": args.trials,
        "batchSize": args.batch_size,
        "leaderboard": leaderboard,
        "byVariant": by_variant,
    }

    run_id = time.strftime("%Y%m%d-%H%M%S", time.gmtime())
    out_dir = args.out_dir / run_id
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / "report.json"
    out_path.write_text(json.dumps(report, indent=2, sort_keys=True))

    print(json.dumps({
        "runId": run_id,
        "reportJson": str(out_path),
        "winner": leaderboard[0]["name"] if leaderboard else None,
        "winnerStrictF1": leaderboard[0]["metrics"]["majority_vote"]["overall_strict"]["f1"] if leaderboard else None,
        "winnerAvgSnapshotStrictF1": leaderboard[0]["oracleSummary"]["avgOverallStrictF1"] if leaderboard else None,
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
