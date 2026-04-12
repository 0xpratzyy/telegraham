#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
from typing import Any

from query_routing_probe import ROUTING_VARIANTS, probe


DEFAULT_ORACLE = Path("/Users/pratyushrungta/telegraham/evals/product_prompt_oracle_v1.json")


def load_oracle(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text())


def score_variant(variant: str, entries: list[dict[str, Any]]) -> dict[str, Any]:
    results: list[dict[str, Any]] = []
    by_family: dict[str, list[dict[str, Any]]] = {}

    for entry in entries:
        observed = probe(entry["query"], variant=variant)
        family_match = observed["family"] == entry["family"]
        engine_match = observed["preferredEngine"] == entry["preferredEngine"]
        mode_match = observed["mode"] == entry["runtimeMode"]
        row = {
            "id": entry["id"],
            "query": entry["query"],
            "expectedFamily": entry["family"],
            "expectedEngine": entry["preferredEngine"],
            "expectedMode": entry["runtimeMode"],
            "why": entry.get("why"),
            "observedFamily": observed["family"],
            "observedEngine": observed["preferredEngine"],
            "observedMode": observed["mode"],
            "familyMatched": family_match,
            "engineMatched": engine_match,
            "modeMatched": mode_match,
        }
        results.append(row)
        by_family.setdefault(entry["family"], []).append(row)

    def family_summary(rows: list[dict[str, Any]]) -> dict[str, Any]:
        family_matches = sum(1 for row in rows if row["familyMatched"])
        engine_matches = sum(1 for row in rows if row["engineMatched"])
        mode_matches = sum(1 for row in rows if row["modeMatched"])
        return {
            "queryCount": len(rows),
            "familyMatched": family_matches,
            "engineMatched": engine_matches,
            "modeMatched": mode_matches,
            "familyCoverage": family_matches / len(rows) if rows else 0.0,
            "engineCoverage": engine_matches / len(rows) if rows else 0.0,
            "modeCoverage": mode_matches / len(rows) if rows else 0.0,
            "misses": [
                {
                    "query": row["query"],
                    "observedFamily": row["observedFamily"],
                    "observedEngine": row["observedEngine"],
                    "observedMode": row["observedMode"],
                }
                for row in rows
                if not (row["familyMatched"] and row["engineMatched"] and row["modeMatched"])
            ],
        }

    by_family_summary = {
        family: family_summary(rows)
        for family, rows in by_family.items()
    }

    family_matches = sum(1 for row in results if row["familyMatched"])
    engine_matches = sum(1 for row in results if row["engineMatched"])
    mode_matches = sum(1 for row in results if row["modeMatched"])
    return {
        "name": variant,
        "summary": {
            "queryCount": len(results),
            "familyMatched": family_matches,
            "engineMatched": engine_matches,
            "modeMatched": mode_matches,
            "familyCoverage": family_matches / len(results) if results else 0.0,
            "engineCoverage": engine_matches / len(results) if results else 0.0,
            "modeCoverage": mode_matches / len(results) if results else 0.0,
            "byFamily": by_family_summary,
        },
        "results": results,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Compare routing variants against the GPT-5.4 product prompt oracle.")
    parser.add_argument("--oracle", type=Path, default=DEFAULT_ORACLE)
    parser.add_argument("--variants", nargs="*", default=sorted(ROUTING_VARIANTS.keys()))
    args = parser.parse_args()

    oracle = load_oracle(args.oracle)
    entries = oracle["entries"]
    leaderboard = [score_variant(variant, entries) for variant in args.variants]
    leaderboard.sort(
        key=lambda row: (
            -row["summary"]["familyCoverage"],
            -row["summary"]["engineCoverage"],
            -row["summary"]["modeCoverage"],
        )
    )

    print(json.dumps({
        "oracle": str(args.oracle),
        "leaderboard": leaderboard,
    }, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
