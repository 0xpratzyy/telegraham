#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
from typing import Any

from query_routing_probe import ROUTING_VARIANTS, probe


DEFAULT_MANIFEST = Path("/Users/pratyushrungta/telegraham/evals/thesis_eval_suite.json")


def load_prompt_coverage(manifest_path: Path) -> dict[str, list[str]]:
    manifest = json.loads(manifest_path.read_text())
    coverage = manifest.get("prompt_coverage", {})
    return {family: [str(query) for query in queries] for family, queries in coverage.items()}


def evaluate_variant(variant: str, prompt_coverage: dict[str, list[str]]) -> dict[str, Any]:
    results: list[dict[str, Any]] = []
    by_family: dict[str, dict[str, Any]] = {}

    for expected_family, queries in prompt_coverage.items():
        family_results: list[dict[str, Any]] = []
        for query in queries:
            payload = probe(query, variant=variant)
            payload["expectedFamily"] = expected_family
            payload["familyMatched"] = payload["family"] == expected_family
            family_results.append(payload)
            results.append(payload)

        matched = sum(1 for item in family_results if item["familyMatched"])
        by_family[expected_family] = {
            "queryCount": len(family_results),
            "matchedFamilyCount": matched,
            "coverageRate": (matched / len(family_results)) if family_results else 0.0,
            "misses": [
                {
                    "query": item["query"],
                    "predictedFamily": item["family"],
                }
                for item in family_results
                if not item["familyMatched"]
            ],
        }

    matched_total = sum(1 for item in results if item["familyMatched"])
    return {
        "name": variant,
        "summary": {
            "queryCount": len(results),
            "matchedFamilyCount": matched_total,
            "coverageRate": (matched_total / len(results)) if results else 0.0,
            "byFamily": by_family,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Compare routing-rule variants against the product prompt catalog.")
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--variants", nargs="*", default=sorted(ROUTING_VARIANTS.keys()))
    args = parser.parse_args()

    prompt_coverage = load_prompt_coverage(args.manifest)
    evaluations = [evaluate_variant(variant, prompt_coverage) for variant in args.variants]
    evaluations.sort(key=lambda item: item["summary"]["coverageRate"], reverse=True)
    print(json.dumps({"manifest": str(args.manifest), "leaderboard": evaluations}, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
