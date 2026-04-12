#!/usr/bin/env python3
import argparse
import json
import subprocess
import time
from pathlib import Path
from typing import Any

from reply_queue_gold_eval import evaluate, load_gold
from reply_queue_harness import leaderboard_rows, summarize_variant
from reply_queue_variant_bench import (
    APP_SUPPORT,
    DEFAULT_API_KEY_PATH,
    DEFAULT_SNAPSHOT_PATH,
    VARIANT_RUNS,
    load_api_key,
    run_variant,
)


DEFAULT_MANIFEST = Path("/Users/pratyushrungta/telegraham/evals/thesis_eval_suite.json")
DEFAULT_OUT_DIR = APP_SUPPORT / "debug" / "thesis_bulk_eval"
DEFAULT_GOLD = Path("/Users/pratyushrungta/telegraham/evals/reply_queue_manual_gold_mixed_recent_48.json")
WORKDIR = Path("/Users/pratyushrungta/telegraham")


def run_command(command: list[str]) -> dict[str, Any]:
    started_at = time.time()
    completed = subprocess.run(
        command,
        cwd=WORKDIR,
        capture_output=True,
        text=True,
    )
    ended_at = time.time()
    return {
        "command": command,
        "exitCode": completed.returncode,
        "stdout": completed.stdout,
        "stderr": completed.stderr,
        "durationMs": int((ended_at - started_at) * 1000),
    }


def run_json_command(command: list[str]) -> dict[str, Any]:
    result = run_command(command)
    if result["exitCode"] != 0:
        raise RuntimeError(
            f"Command failed: {' '.join(command)}\nstdout:\n{result['stdout']}\nstderr:\n{result['stderr']}"
        )
    payload = json.loads(result["stdout"])
    payload["_meta"] = {
        "command": command,
        "durationMs": result["durationMs"],
    }
    return payload


def prompt_coverage_from_manifest(manifest: dict[str, Any]) -> dict[str, list[str]]:
    if "prompt_coverage" in manifest:
        return {
            family: [str(query) for query in queries]
            for family, queries in manifest["prompt_coverage"].items()
        }

    return {
        "exact_lookup": [str(query) for query in manifest.get("exact_lookup_queries", [])],
        "topic_search": [str(query) for query in manifest.get("topic_search_queries", [])],
        "reply_queue": [str(query) for query in manifest.get("reply_queue_queries", [])],
        "summary": [str(query) for query in manifest.get("summary_queries", [])],
        "relationship": [str(query) for query in manifest.get("relationship_queries", [])],
    }


def run_routing_suite(prompt_coverage: dict[str, list[str]]) -> dict[str, Any]:
    results: list[dict[str, Any]] = []
    family_summary: dict[str, dict[str, Any]] = {}

    for expected_family, queries in prompt_coverage.items():
        family_results: list[dict[str, Any]] = []
        for query in queries:
            payload = run_json_command(
                ["/usr/bin/python3", "/Users/pratyushrungta/telegraham/tools/query_routing_probe.py", query]
            )
            payload["expectedFamily"] = expected_family
            payload["familyMatched"] = payload["family"] == expected_family
            family_results.append(payload)
            results.append(payload)

        matched_count = sum(1 for item in family_results if item["familyMatched"])
        family_summary[expected_family] = {
            "queryCount": len(family_results),
            "matchedFamilyCount": matched_count,
            "coverageRate": (matched_count / len(family_results)) if family_results else 0.0,
        }

    matched_total = sum(1 for item in results if item["familyMatched"])
    return {
        "queries": results,
        "summary": {
            "queryCount": len(results),
            "matchedFamilyCount": matched_total,
            "coverageRate": (matched_total / len(results)) if results else 0.0,
            "byFamily": family_summary,
        },
    }


def run_exact_lookup_suite(queries: list[str]) -> dict[str, Any]:
    results: list[dict[str, Any]] = []
    for query in queries:
        payload = run_json_command(
            ["/usr/bin/python3", "/Users/pratyushrungta/telegraham/tools/exact_lookup_probe.py", query]
        )
        results.append(payload)

    return {
        "queries": results,
        "summary": {
            "queryCount": len(results),
            "withDirectArtifactAndRecipientHits": sum(1 for item in results if item["directArtifactAndRecipientHitCount"] > 0),
            "withSameChatOverlap": sum(1 for item in results if item["sameChatArtifactAndRecipientOverlapCount"] > 0),
        },
    }


def run_topic_search_suite(queries: list[str]) -> dict[str, Any]:
    results: list[dict[str, Any]] = []
    for query in queries:
        payload = run_json_command(
            ["/usr/bin/python3", "/Users/pratyushrungta/telegraham/tools/topic_search_probe.py", query]
        )
        results.append(payload)

    return {
        "queries": results,
        "summary": {
            "queryCount": len(results),
            "withMessageHits": sum(1 for item in results if item["messageHitCount"] > 0),
            "withChatRollups": sum(1 for item in results if item["chatRollupCount"] > 0),
        },
    }


def run_reply_queue_suite(config: dict[str, Any]) -> dict[str, Any]:
    if not config.get("enabled", True):
        return {"enabled": False}

    variants_by_name = {variant.name: variant for variant in VARIANT_RUNS}
    variant_names = config.get("variants") or [variant.name for variant in VARIANT_RUNS]
    variants = [variants_by_name[name] for name in variant_names]
    snapshot_path = Path(config.get("snapshot", str(DEFAULT_SNAPSHOT_PATH)))
    gold_path = Path(config.get("gold", str(DEFAULT_GOLD)))
    api_key_path = Path(config.get("apiKeyFile", str(DEFAULT_API_KEY_PATH)))
    trials = int(config.get("trials", 1))
    batch_size = int(config.get("batch_size", 12))

    snapshot = json.loads(snapshot_path.read_text())
    labels = load_gold(gold_path)
    api_key = load_api_key(api_key_path)

    try:
        aggregates: list[dict[str, Any]] = []
        raw_trials: dict[str, list[dict[str, Any]]] = {}
        for variant in variants:
            variant_trials: list[dict[str, Any]] = []
            variant_reports: list[dict[str, Any]] = []
            for _ in range(trials):
                payload = run_variant(api_key, snapshot, variant, batch_size)
                predicted = {int(chat_id) for chat_id in payload.get("on_me_chat_ids", [])}
                report = evaluate(variant.name, predicted, labels)
                payload["evaluation"] = report
                variant_trials.append(payload)
                variant_reports.append(report)
            raw_trials[variant.name] = variant_trials
            aggregates.append(summarize_variant(variant, variant_trials, variant_reports, labels))

        leaderboard = leaderboard_rows(aggregates)
        return {
            "enabled": True,
            "status": "ok",
            "snapshot": str(snapshot_path),
            "gold": str(gold_path),
            "variants": [variant.name for variant in variants],
            "trials": trials,
            "batchSize": batch_size,
            "leaderboard": leaderboard,
            "rawTrials": raw_trials,
        }
    except Exception as error:
        return {
            "enabled": True,
            "status": "error",
            "snapshot": str(snapshot_path),
            "gold": str(gold_path),
            "variants": [variant.name for variant in variants],
            "trials": trials,
            "batchSize": batch_size,
            "error": str(error),
        }


def render_markdown(
    manifest: dict[str, Any],
    test_gate: dict[str, Any],
    routing: dict[str, Any],
    exact_lookup: dict[str, Any],
    topic_search: dict[str, Any],
    reply_queue: dict[str, Any],
) -> str:
    lines = [
        "# MVP Thesis Bulk Eval",
        "",
        f"Suite: `{manifest.get('name', 'unnamed-suite')}`",
        "",
        "## Test Gate",
        "",
        f"- `xcodebuild test`: `{'passed' if test_gate['exitCode'] == 0 else 'failed'}` in `{test_gate['durationMs']}ms`",
    ]

    lines.extend(
        [
            "",
            "## Routing Coverage",
            "",
            f"- Queries: `{routing['summary']['queryCount']}`",
            f"- Expected-family matches: `{routing['summary']['matchedFamilyCount']}`",
            f"- Coverage rate: `{routing['summary']['coverageRate']:.0%}`",
        ]
    )
    for family, summary in routing["summary"]["byFamily"].items():
        lines.append(
            f"- `{family}` → `{summary['matchedFamilyCount']}/{summary['queryCount']}` (`{summary['coverageRate']:.0%}`)"
        )

    lines.extend(
        [
            "",
            "## Exact Lookup",
            "",
            f"- Queries: `{exact_lookup['summary']['queryCount']}`",
            f"- Direct artifact+recipient hits: `{exact_lookup['summary']['withDirectArtifactAndRecipientHits']}`",
            f"- Same-chat artifact/recipient overlap: `{exact_lookup['summary']['withSameChatOverlap']}`",
        ]
    )
    for item in exact_lookup["queries"]:
        lines.append(
            f"- `{item['query']}` → direct hits `{item['directArtifactAndRecipientHitCount']}`, same-chat overlap `{item['sameChatArtifactAndRecipientOverlapCount']}`"
        )

    lines.extend(
        [
            "",
            "## Topic Search",
            "",
            f"- Queries: `{topic_search['summary']['queryCount']}`",
            f"- Queries with message hits: `{topic_search['summary']['withMessageHits']}`",
            f"- Queries with chat rollups: `{topic_search['summary']['withChatRollups']}`",
        ]
    )
    for item in topic_search["queries"]:
        lines.append(
            f"- `{item['query']}` → message hits `{item['messageHitCount']}`, chat rollups `{item['chatRollupCount']}`"
        )

    lines.extend(
        [
            "",
            "## Summary",
            "",
            f"- Prompt paraphrases in routing suite: `{routing['summary']['byFamily'].get('summary', {}).get('queryCount', 0)}`",
            "- Quality is still covered by the unit test gate today, not by a dedicated bulk synthesis harness yet.",
        ]
    )

    lines.extend(
        [
            "",
            "## Reply Queue",
            "",
        ]
    )
    if not reply_queue.get("enabled", True):
        lines.append("- Disabled for this suite run.")
    elif reply_queue.get("status") == "error":
        lines.append(f"- Error: `{reply_queue['error']}`")
    else:
        best = reply_queue["leaderboard"][0]
        lines.append(f"- Winner: `{best['name']}`")
        lines.append(f"- Strict F1: `{best['metrics']['majority_vote']['overall_strict']['f1']:.2f}`")
        lines.append(f"- Group lenient F1: `{best['metrics']['majority_vote']['groups_lenient']['f1']:.2f}`")
        lines.append(f"- Median latency: `{best['latency']['median_ms']}ms`")

    lines.extend(
        [
            "",
            "## Gaps",
            "",
            "- Summary still lacks a dedicated bulk query harness.",
        ]
    )
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="Run the current MVP thesis suite in bulk and write one consolidated report.")
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    parser.add_argument("--skip-tests", action="store_true")
    parser.add_argument("--skip-reply-queue", action="store_true")
    args = parser.parse_args()

    manifest = json.loads(args.manifest.read_text())
    prompt_coverage = prompt_coverage_from_manifest(manifest)
    run_id = time.strftime("%Y%m%d-%H%M%S", time.gmtime())
    out_dir = args.out_dir / run_id
    out_dir.mkdir(parents=True, exist_ok=True)

    if args.skip_tests:
        test_gate = {
            "command": ["/usr/bin/xcodebuild", "test", "-scheme", "Pidgy", "-destination", "platform=macOS"],
            "exitCode": 0,
            "stdout": "",
            "stderr": "",
            "durationMs": 0,
            "skipped": True,
        }
    else:
        test_gate = run_command(
            ["/usr/bin/xcodebuild", "test", "-scheme", "Pidgy", "-destination", "platform=macOS"]
        )

    routing = run_routing_suite(prompt_coverage)
    exact_lookup = run_exact_lookup_suite(prompt_coverage.get("exact_lookup", []))
    topic_search = run_topic_search_suite(prompt_coverage.get("topic_search", []))

    reply_queue_config = dict(manifest.get("reply_queue", {}))
    if args.skip_reply_queue:
        reply_queue_config["enabled"] = False
    reply_queue = run_reply_queue_suite(reply_queue_config)

    report = {
        "capturedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "manifest": manifest,
        "testGate": test_gate,
        "routing": routing,
        "exactLookup": exact_lookup,
        "topicSearch": topic_search,
        "summary": {
            "queries": prompt_coverage.get("summary", []),
            "status": "routing_covered_quality_by_unit_tests_only",
        },
        "replyQueue": reply_queue,
        "gaps": [
            "summary lacks a dedicated bulk query harness",
        ],
    }

    report_json = out_dir / "report.json"
    report_md = out_dir / "report.md"
    report_json.write_text(json.dumps(report, indent=2, sort_keys=True))
    report_md.write_text(render_markdown(manifest, test_gate, routing, exact_lookup, topic_search, reply_queue))

    summary = {
        "runId": run_id,
        "reportJson": str(report_json),
        "reportMarkdown": str(report_md),
        "testsPassed": test_gate["exitCode"] == 0,
        "routingQueries": routing["summary"]["queryCount"],
        "routingCoverageRate": routing["summary"]["coverageRate"],
        "exactLookupQueries": exact_lookup["summary"]["queryCount"],
        "topicSearchQueries": topic_search["summary"]["queryCount"],
    }
    if reply_queue.get("enabled") and reply_queue.get("status") == "ok":
        winner = reply_queue["leaderboard"][0]
        summary["replyQueueWinner"] = winner["name"]
        summary["replyQueueWinnerStrictF1"] = winner["metrics"]["majority_vote"]["overall_strict"]["f1"]
    elif reply_queue.get("enabled") and reply_queue.get("status") == "error":
        summary["replyQueueError"] = reply_queue["error"]
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
