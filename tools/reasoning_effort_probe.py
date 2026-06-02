#!/usr/bin/env python3
"""reasoning_effort_probe.py — Lever 1 cost test (no product changes).

Does gpt-5 with reasoning_effort="minimal" (and optionally verbosity="low") cut the
output/reasoning tokens that dominate pipelineTriage cost, WITHOUT changing the
decisions vs the current "low" setting?

Uses real gpt-5 via OpenRouter (no OpenAI key on disk; same model, so the low-vs-
minimal comparison is valid). Reuses the replay dataset from model_swap_eval.py
build-db. Reference = pipeline_cache (the app's real gpt-5-low decisions).

Set OPENAI_API_KEY in .env.eval.local to call OpenAI directly instead (flip USE_OPENAI).

  python3 tools/reasoning_effort_probe.py            # 10+10+10 balanced subset
  python3 tools/reasoning_effort_probe.py --n 60
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import model_swap_eval as mse  # reuse dataset loader + parse_decision

OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"
CATEGORIES = mse.CATEGORIES

# OpenRouter reasoning config is nested under "reasoning"; verbosity is top-level.
CONFIGS = [
    ("low (current)", {"reasoning": {"effort": "low"}}),
    ("minimal", {"reasoning": {"effort": "minimal"}}),
    ("minimal+verb_low", {"reasoning": {"effort": "minimal"}, "verbosity": "low"}),
]


def call_gpt5(key: str, system: str, user: str, extra: dict) -> dict:
    body = {
        "model": "openai/gpt-5",
        "messages": [{"role": "system", "content": system},
                     {"role": "user", "content": user}],
        "response_format": {"type": "json_object"},
        "max_tokens": 2000,
        "usage": {"include": True},
        **extra,
    }
    req = urllib.request.Request(OPENROUTER_URL, data=json.dumps(body).encode(), method="POST",
                                 headers={"Authorization": f"Bearer {key}",
                                          "Content-Type": "application/json"})
    t = time.time()
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            d = json.loads(r.read())
    except urllib.error.HTTPError as e:
        return {"error": f"http_{e.code}: {e.read().decode()[:160]}", "lat": time.time() - t}
    except Exception as e:  # noqa: BLE001
        return {"error": f"{type(e).__name__}: {e}", "lat": time.time() - t}
    u = d.get("usage", {}) or {}
    pdet = u.get("prompt_tokens_details", {}) or {}
    cdet = u.get("completion_tokens_details", {}) or {}
    try:
        text = d["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError):
        return {"error": f"no content: {json.dumps(d)[:160]}", "lat": time.time() - t}
    return {"text": text, "in": u.get("prompt_tokens", 0) or 0,
            "cached": pdet.get("cached_tokens", 0) or 0,
            "out": u.get("completion_tokens", 0) or 0,
            "reasoning": cdet.get("reasoning_tokens", 0) or 0,
            "cost": float(u.get("cost", 0) or 0), "lat": time.time() - t}


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--n", type=int, default=30, help="total examples (balanced across classes)")
    p.add_argument("--concurrency", type=int, default=5)
    args = p.parse_args()

    mse.load_env()
    key = os.environ.get("OPENROUTER_API_KEY", "").strip()
    if not key:
        sys.exit("OPENROUTER_API_KEY not set (in .env.eval.local).")

    rows = mse.load_dataset(None)
    by = {c: [r for r in rows if r["ref_category"] == c] for c in CATEGORIES}
    per = max(1, args.n // 3)
    subset = by["on_me"][:per] + by["on_them"][:per] + by["quiet"][:per]
    print(f"probe: {len(subset)} examples (balanced) x {len(CONFIGS)} configs on openai/gpt-5\n")

    results = {}
    for label, extra in CONFIGS:
        agg = {"n": 0, "valid": 0, "agree": 0, "out": 0, "reasoning": 0, "cost": 0.0,
               "lat": [], "err": 0, "errmsg": None, "byclass": defaultdict(lambda: [0, 0])}
        preds = {}

        def work(r):
            return r, call_gpt5(key, r["system"], r["user"], extra)

        with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
            for fut in as_completed([pool.submit(work, r) for r in subset]):
                r, res = fut.result()
                agg["n"] += 1
                if res.get("error"):
                    agg["err"] += 1
                    agg["errmsg"] = agg["errmsg"] or res["error"]
                    continue
                agg["valid"] += 1
                agg["out"] += res["out"]; agg["reasoning"] += res["reasoning"]
                agg["cost"] += res["cost"]; agg["lat"].append(res["lat"])
                cat = mse.parse_decision(res["text"]).get("category")
                preds[r["trace_id"]] = cat
                ref = r["ref_category"]; agg["byclass"][ref][1] += 1
                if cat == ref:
                    agg["agree"] += 1; agg["byclass"][ref][0] += 1
        results[label] = (agg, preds)
        v = agg["valid"] or 1
        lat = sorted(agg["lat"]); p50 = lat[len(lat) // 2] if lat else 0
        print(f"### {label}: valid={agg['valid']}/{agg['n']} err={agg['err']}"
              + (f"  ({agg['errmsg']})" if agg["err"] else ""))
        if agg["valid"]:
            extra_r = f"  avg_reasoning={agg['reasoning']/v:.0f}tok" if agg["reasoning"] else ""
            print(f"  agree vs cache = {100*agg['agree']/v:.1f}%   avg_out={agg['out']/v:.0f}tok{extra_r}   "
                  f"$/call=${agg['cost']/v:.5f}   p50={p50:.1f}s")
            print("  per-class recall: " + "  ".join(
                f"{c}={100*agg['byclass'][c][0]/agg['byclass'][c][1]:.0f}%({agg['byclass'][c][0]}/{agg['byclass'][c][1]})"
                for c in CATEGORIES if agg['byclass'][c][1]))
        print()

    base_agg, base_preds = results["low (current)"]
    if base_agg["valid"]:
        print("=== vs current 'low' (same inputs) ===")
        for label, _ in CONFIGS[1:]:
            cagg, cpreds = results[label]
            if not cagg["valid"]:
                print(f"{label}: FAILED — {cagg['errmsg']}")
                continue
            common = [t for t in base_preds if t in cpreds and base_preds[t] and cpreds[t]]
            same = sum(1 for t in common if base_preds[t] == cpreds[t])
            bv, cv = base_agg["valid"], cagg["valid"]
            out_cut = 100 * (1 - (cagg["out"]/cv) / (base_agg["out"]/bv)) if base_agg["out"] else 0
            cost_cut = 100 * (1 - (cagg["cost"]/cv) / (base_agg["cost"]/bv)) if base_agg["cost"] else 0
            print(f"{label}: same decision as low = {100*same/len(common):.0f}% "
                  f"({same}/{len(common)})  |  output -{out_cut:.0f}%  |  cost -{cost_cut:.0f}%")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
