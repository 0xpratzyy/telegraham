#!/usr/bin/env python3
"""model_version_probe.py — gpt-5.0 vs 5.4 vs 5.5 at low/minimal reasoning, on
pipelineTriage, via the PRODUCT OpenAI API (api.openai.com — same call the app makes).

Reference = pipeline_cache (the app's real gpt-5-low decisions). Reuses the replay
dataset from model_swap_eval.py build-db. Reads OPENAI_API_KEY from .env.eval.local.

  python3 tools/model_version_probe.py --n 30
"""
from __future__ import annotations
import argparse, json, os, sys, time, urllib.request, urllib.error
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import model_swap_eval as mse

OPENAI_URL = "https://api.openai.com/v1/chat/completions"
CATS = mse.CATEGORIES
# (model, reasoning_effort)
CONFIGS = [("gpt-5", "low"), ("gpt-5", "minimal"),
           ("gpt-5.4", "low"), ("gpt-5.4", "minimal"),
           ("gpt-5.5", "low"), ("gpt-5.5", "minimal")]
# $/token (input, cached, output). gpt-5 known; 5.4/5.5 filled from OpenRouter if found.
PRICE = {"gpt-5": (1.25e-6, 0.125e-6, 10e-6)}


def fill_prices():
    try:
        data = json.load(urllib.request.urlopen("https://openrouter.ai/api/v1/models", timeout=30))["data"]
        idx = {m["id"]: m for m in data}
        for short in ("gpt-5.4", "gpt-5.5"):
            m = idx.get(f"openai/{short}")
            if m:
                p = m.get("pricing", {})
                PRICE[short] = (float(p.get("prompt", 0) or 0),
                                float(p.get("input_cache_read", 0) or p.get("prompt", 0) or 0),
                                float(p.get("completion", 0) or 0))
    except Exception:  # noqa: BLE001
        pass


def call(key, model, effort, system, user):
    body = {"model": model,
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
            "response_format": {"type": "json_object"},
            "max_completion_tokens": 2000, "reasoning_effort": effort}
    req = urllib.request.Request(OPENAI_URL, data=json.dumps(body).encode(), method="POST",
                                 headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    t = time.time()
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            d = json.loads(r.read())
    except urllib.error.HTTPError as e:
        return {"error": f"http_{e.code}: {e.read().decode()[:140]}", "lat": time.time() - t}
    except Exception as e:  # noqa: BLE001
        return {"error": str(e)[:140], "lat": time.time() - t}
    u = d.get("usage", {}) or {}
    pdet = u.get("prompt_tokens_details", {}) or {}
    cdet = u.get("completion_tokens_details", {}) or {}
    try:
        text = d["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError):
        return {"error": f"no content: {json.dumps(d)[:140]}", "lat": time.time() - t}
    return {"text": text, "in": u.get("prompt_tokens", 0) or 0, "cached": pdet.get("cached_tokens", 0) or 0,
            "out": u.get("completion_tokens", 0) or 0, "reasoning": cdet.get("reasoning_tokens", 0) or 0,
            "lat": time.time() - t}


def cost_of(model, r):
    pin, pc, pout = PRICE.get(model, PRICE["gpt-5"])
    return (r["in"] - r["cached"]) * pin + r["cached"] * pc + r["out"] * pout


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--n", type=int, default=30)
    p.add_argument("--concurrency", type=int, default=6)
    args = p.parse_args()
    mse.load_env()
    key = os.environ.get("OPENAI_API_KEY", "").strip()
    if not key:
        sys.exit("OPENAI_API_KEY not set in .env.eval.local")
    fill_prices()
    rows = mse.load_dataset(None)
    by = {c: [r for r in rows if r["ref_category"] == c] for c in CATS}
    per = max(1, args.n // 3)
    subset = by["on_me"][:per] + by["on_them"][:per] + by["quiet"][:per]
    print(f"{len(subset)} examples (balanced) x {len(CONFIGS)} configs via OpenAI API")
    print(f"prices known: {', '.join(sorted(PRICE))}\n")

    results = {}
    for model, effort in CONFIGS:
        label = f"{model} {effort}"
        agg = {"n": 0, "valid": 0, "agree": 0, "out": 0, "reasoning": 0, "cost": 0.0,
               "lat": [], "err": 0, "errmsg": None, "byc": defaultdict(lambda: [0, 0])}
        preds = {}

        def work(r):
            return r, call(key, model, effort, r["system"], r["user"])

        with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
            for fut in as_completed([pool.submit(work, r) for r in subset]):
                r, res = fut.result(); agg["n"] += 1
                if res.get("error"):
                    agg["err"] += 1; agg["errmsg"] = agg["errmsg"] or res["error"]; continue
                agg["valid"] += 1; agg["out"] += res["out"]; agg["reasoning"] += res["reasoning"]
                agg["cost"] += cost_of(model, res); agg["lat"].append(res["lat"])
                cat = mse.parse_decision(res["text"]).get("category"); ref = r["ref_category"]
                preds[r["trace_id"]] = cat; agg["byc"][ref][1] += 1
                if cat == ref:
                    agg["agree"] += 1; agg["byc"][ref][0] += 1
        results[label] = (agg, preds)
        v = agg["valid"] or 1
        lat = sorted(agg["lat"]); p50 = lat[len(lat) // 2] if lat else 0
        cflag = "" if model in PRICE else " (cost≈gpt-5 px)"
        print(f"{label:16} agree={100*agg['agree']/v:4.1f}%  on_me={100*agg['byc']['on_me'][0]/max(1,agg['byc']['on_me'][1]):3.0f}%"
              f"  on_them={100*agg['byc']['on_them'][0]/max(1,agg['byc']['on_them'][1]):3.0f}%"
              f"  quiet={100*agg['byc']['quiet'][0]/max(1,agg['byc']['quiet'][1]):3.0f}%"
              f"  out={agg['out']/v:4.0f}  reas={agg['reasoning']/v:4.0f}  ${agg['cost']/v:.5f}/call{cflag}"
              f"  {p50:4.1f}s  err={agg['err']}")
    # targeted comparison: 5.4/5.5 low (and minimal) vs 5.0 minimal
    base = "gpt-5 minimal"
    if results.get(base, (None,))[0] and results[base][0]["valid"]:
        ba = results[base][0]; bv = ba["valid"]
        print(f"\n=== vs anchor '{base}' (agree {100*ba['agree']/bv:.0f}%, ${ba['cost']/bv:.5f}/call) ===")
        for label, _ in [(f"{m} {e}", None) for m, e in CONFIGS if label_ne(m, e, base)]:
            ca = results[label][0]
            if not ca["valid"]: continue
            cv = ca["valid"]
            print(f"  {label:16} agree {100*ca['agree']/cv:4.1f}%  (Δ{100*ca['agree']/cv-100*ba['agree']/bv:+.1f}pts)  "
                  f"${ca['cost']/cv:.5f}/call  {('×%.1f'%((ca['cost']/cv)/(ba['cost']/bv))) if ba['cost'] else ''}")
    return 0


def label_ne(m, e, base):
    return f"{m} {e}" != base


if __name__ == "__main__":
    raise SystemExit(main())
