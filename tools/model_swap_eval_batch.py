#!/usr/bin/env python3
"""
model_swap_eval_batch.py — does a cheaper model degrade on the LARGE-input call?

The reply queue's agentic-search call ranks up to AppConstants.batchSize=50 chats
in ONE request (~10-30k tokens) and must return exactly one result per candidate.
That's where small models are expected to break down (dropped/duplicated
candidates, worse ranking) — unlike the small per-chat pipelineTriage call.

This builds NESTED batches from the local DB — the same chats at sizes 10 -> 25
-> 50 — so we can watch each model's behaviour on identical chats as the
surrounding input grows. gpt-5 is the reference at each size. We score:
  - cardinality:   did the model return exactly one result per input chatId?
  - reply_now agree: per-candidate replyability vs gpt-5 at the same size
  - drift:         do the shared first-10 chats keep their replyability as the
                   batch grows from 10 -> 50?

Reuses model_swap_eval.py for the OpenRouter client, key loading, and DB shape.

Usage:
  python3 tools/model_swap_eval_batch.py build   --pools 2
  python3 tools/model_swap_eval_batch.py sweep   --models openai/gpt-5,openai/gpt-5-mini,qwen/qwen3.7-max
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import textwrap
import time
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import model_swap_eval as mse  # noqa: E402  reuse client, keys, DB conventions

OUT = mse.OUT_DIR
BATCH_DATASET = OUT / "agentic_batches.jsonl"
BATCH_SUMMARY = OUT / "batch_summary.json"
AGENTIC_SWIFT = mse.REPO_ROOT / "Sources" / "AI" / "Prompts" / "AgenticSearchPrompt.swift"
SIZES = [10, 25, 50]
POOL = 50  # largest batch / pool size

# A realistic strict reply-queue query (mirrors the app's reply-queue path).
QUERY = "who do I still need to reply to"
CONSTRAINTS = ("Hard constraints:\n- scope: all\n- replyConstraint: pipeline_on_me_only\n"
               "- timeRange: none\n- parseConfidence: 0.90\n")


def agentic_system_prompt() -> str:
    txt = AGENTIC_SWIFT.read_text(encoding="utf-8")
    m = re.search(r'static let systemPrompt = """\n(.*?)\n\s*"""', txt, re.DOTALL)
    if not m:
        sys.exit("could not extract AgenticSearchPrompt.systemPrompt")
    return textwrap.dedent(m.group(1))


# ---------------------------------------------------------------------------
# build — nested agentic batches from the local DB
# ---------------------------------------------------------------------------
def _candidate_block(chat_id, name, category, strict, msg_lines) -> str:
    out = (f"\n---\nchatId: {chat_id}\nchatName: {name}\n"
           f"pipelineCategory: {category}\nstrictReplySignal: {strict}\n"
           f"Messages (oldest first):\n")
    return out + "".join(msg_lines)


def cmd_build(args):
    import sqlite3
    db = Path(args.db).expanduser()
    if not db.exists():
        sys.exit(f"DB not found: {db}")
    conn = sqlite3.connect(str(db))
    conn.row_factory = sqlite3.Row
    nodes = {str(r["entity_id"]): r for r in conn.execute(
        "SELECT entity_id, entity_type, display_name FROM nodes")}
    me = conn.execute("SELECT sender_name, COUNT(*) c FROM messages WHERE is_outgoing=1 "
                      "AND sender_name<>'' GROUP BY sender_name ORDER BY c DESC LIMIT 1").fetchone()
    me_name = me[0] if me else "Me"

    # bucket cache chats by category so each pool/batch prefix has a real mix
    buckets = defaultdict(list)
    for r in conn.execute("SELECT chat_id, category, last_message_id, analyzed_at "
                          "FROM pipeline_cache ORDER BY analyzed_at DESC"):
        if r["category"] in mse.CATEGORIES:
            buckets[r["category"]].append(r)

    def build_candidate(r):
        chat_id = str(r["chat_id"])
        node = nodes.get(chat_id)
        name = node["display_name"] if node and node["display_name"] else f"Chat {chat_id}"
        ctype = (node["entity_type"] if node else "user")
        is_dm = (ctype or "").lower() in mse.DM_TYPES
        last_mid = int(r["last_message_id"]) if r["last_message_id"] else None
        now = float(r["analyzed_at"]) if r["analyzed_at"] else time.time()
        q = "SELECT id,date,sender_name,is_outgoing,text_content FROM messages WHERE chat_id=?"
        p = [int(r["chat_id"])]
        if last_mid:
            q += " AND id<=?"; p.append(last_mid)
        q += " ORDER BY date DESC,id DESC LIMIT ?"; p.append(args.window)
        rows = list(reversed(conn.execute(q, p).fetchall()))
        if not rows:
            return None
        lines = []
        for m in rows:
            who = "[ME]" if int(m["is_outgoing"] or 0) else (m["sender_name"] or (name if is_dm else "Unknown"))
            text = " ".join((m["text_content"] or "").split()) or "[non-text message]"
            lines.append(f"[messageId: {m['id']}] [{mse._relative_ts(float(m['date']), now)}] {who}: {text}\n")
        return {"chatId": chat_id, "name": name, "category": r["category"],
                "strict": "true" if r["category"] == "on_me" else "false", "lines": lines}

    # interleave on_me / on_them / quiet so the nested prefixes stay balanced
    order = []
    bi = {k: iter(v) for k, v in buckets.items()}
    while len(order) < POOL * args.pools:
        added = False
        for cat in ("on_me", "on_them", "quiet"):
            nxt = next(bi[cat], None)
            if nxt is not None:
                c = build_candidate(nxt)
                if c:
                    order.append(c); added = True
        if not added:
            break
    conn.close()

    OUT.mkdir(parents=True, exist_ok=True)
    sysprompt = agentic_system_prompt()
    rows_out = []
    for pool_i in range(args.pools):
        pool = order[pool_i * POOL:(pool_i + 1) * POOL]
        if len(pool) < max(SIZES):
            break
        for size in SIZES:
            cands = pool[:size]
            user = f'User query: "{QUERY}"\n\n{CONSTRAINTS}\nCandidate chats:\n'
            user += "".join(_candidate_block(c["chatId"], c["name"], c["category"], c["strict"], c["lines"]) for c in cands)
            rows_out.append({
                "batch_id": f"p{pool_i}_n{size}", "pool": pool_i, "size": size,
                "system": sysprompt, "user": user,
                "chat_ids": [c["chatId"] for c in cands],
                "categories": {c["chatId"]: c["category"] for c in cands},
            })
    with BATCH_DATASET.open("w", encoding="utf-8") as f:
        for r in rows_out:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    sizes = defaultdict(int)
    for r in rows_out:
        sizes[r["size"]] += 1
    print(f"[build] wrote {len(rows_out)} batches -> {BATCH_DATASET}")
    print(f"[build] {args.pools} pool(s) x sizes {dict(sizes)}  (nested: first 10 chats shared across sizes)")
    print(f"[build] approx input tokens: size50≈{len(rows_out and rows_out[-1]['user'])//4} chars/4")


# ---------------------------------------------------------------------------
# parse agentic response
# ---------------------------------------------------------------------------
def parse_agentic(text):
    """-> dict {chatId(str): replyability} or None. Also returns raw count info."""
    if not text:
        return None
    obj = None
    try:
        obj = json.loads(text)
    except Exception:  # noqa: BLE001
        m = re.search(r"\{.*\}", text, re.DOTALL)
        if m:
            try:
                obj = json.loads(m.group(0))
            except Exception:  # noqa: BLE001
                return None
    if not isinstance(obj, dict) or "results" not in obj:
        return None
    out = {}
    dups = 0
    for r in obj.get("results") or []:
        if not isinstance(r, dict) or "chatId" not in r:
            continue
        cid = str(r["chatId"])
        if cid in out:
            dups += 1
        out[cid] = (r.get("replyability") or "").strip()
    return {"map": out, "dups": dups}


# ---------------------------------------------------------------------------
# sweep
# ---------------------------------------------------------------------------
def cmd_sweep(args):
    key = mse.require_key("OPENROUTER_API_KEY")
    if not BATCH_DATASET.exists():
        sys.exit("no batch dataset; run `build` first")
    batches = [json.loads(l) for l in BATCH_DATASET.read_text().splitlines() if l.strip()]
    models = [m.strip() for m in args.models.split(",") if m.strip()]
    ref_model = args.ref
    if ref_model not in models:
        models = [ref_model] + models
    print(f"[sweep] {len(batches)} batches x {len(models)} models; ref={ref_model}")

    # run ref first on every batch (need its per-batch answers before scoring others)
    def run(model, batch):
        n = batch["size"]
        res = mse.openrouter_chat(model, batch["system"], batch["user"], key,
                                  max_tokens=min(8000, n * 150 + 1200))
        parsed = parse_agentic(res.text) if not res.error else None
        return {"model": model, "batch_id": batch["batch_id"], "size": n,
                "parsed": parsed, "cost": res.cost_usd, "latency": res.latency_s,
                "error": res.error, "chat_ids": batch["chat_ids"]}

    ref_by_batch = {}
    print(f"[sweep] reference pass: {ref_model}")
    with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        for fut in as_completed([pool.submit(run, ref_model, b) for b in batches]):
            r = fut.result(); ref_by_batch[r["batch_id"]] = r
            print(f"  {r['batch_id']}: ret={len(r['parsed']['map']) if r['parsed'] else 'ERR'}/{r['size']} "
                  f"${r['cost']:.4f} {r['latency']:.1f}s")

    # candidates
    agg = defaultdict(lambda: defaultdict(lambda: {"batches": 0, "card_ok": 0, "missing": 0, "dups": 0,
                                                   "agree_n": 0, "agree_d": 0, "rn_hit": 0, "rn_ref": 0,
                                                   "cost": 0.0, "lat": [], "valid": 0, "err": 0}))
    drift = defaultdict(dict)  # model -> {chatId -> {size -> replyability}} for shared first-10
    for model in models:
        print(f"[sweep] {model}")
        if model == ref_model:
            results = list(ref_by_batch.values())  # reuse ref pass — don't pay for gpt-5 twice
        else:
            with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
                results = [fut.result() for fut in as_completed([pool.submit(run, model, b) for b in batches])]
        for r in results:
            a = agg[model][r["size"]]; a["batches"] += 1; a["cost"] += r["cost"]; a["lat"].append(r["latency"])
            if r["error"] or not r["parsed"]:
                a["err"] += 1; continue
            a["valid"] += 1
            m = r["parsed"]["map"]; a["dups"] += r["parsed"]["dups"]
            input_ids = set(r["chat_ids"]); returned = set(m.keys())
            missing = input_ids - returned
            a["missing"] += len(missing)
            if returned == input_ids and r["parsed"]["dups"] == 0:
                a["card_ok"] += 1
            ref = ref_by_batch.get(r["batch_id"])
            if ref and ref["parsed"]:
                rmap = ref["parsed"]["map"]
                for cid in input_ids:
                    if cid in m and cid in rmap:
                        a["agree_d"] += 1
                        if m[cid] == rmap[cid]:
                            a["agree_n"] += 1
                    if rmap.get(cid) == "reply_now":
                        a["rn_ref"] += 1
                        if m.get(cid) == "reply_now":
                            a["rn_hit"] += 1
            # drift on shared first-10 chats
            for cid in r["chat_ids"][:10]:
                drift[model].setdefault(cid, {})[r["size"]] = m.get(cid, "MISSING")

    # ---- report ----
    print("\n" + "=" * 92)
    print(f"{'model':24}{'size':>5}{'card_ok':>9}{'missing':>8}{'replyAgree':>11}{'rn_recall':>10}{'valid':>7}{'$/call':>9}{'p50s':>7}")
    print("-" * 92)
    for model in models:
        for size in SIZES:
            a = agg[model].get(size)
            if not a or not a["batches"]:
                continue
            lat = sorted(a["lat"]); p50 = lat[len(lat)//2] if lat else 0
            card = f"{100*a['card_ok']/a['batches']:.0f}%"
            miss = a["missing"]
            agree = f"{100*a['agree_n']/a['agree_d']:.0f}%" if a["agree_d"] else "-"
            rn = f"{100*a['rn_hit']/a['rn_ref']:.0f}%" if a["rn_ref"] else "-"
            valid = f"{100*a['valid']/a['batches']:.0f}%"
            cps = a["cost"]/a["batches"]
            tag = "  <-ref" if model == ref_model else ""
            print(f"{model:24}{size:>5}{card:>9}{miss:>8}{agree:>11}{rn:>10}{valid:>7}{cps:>9.4f}{p50:>7.1f}{tag}")
    print("=" * 92)
    print("card_ok=returned exactly the N input chats (no miss/dup) | replyAgree/rn_recall vs gpt-5 at same size")

    BATCH_SUMMARY.write_text(json.dumps({"models": models, "ref": ref_model,
        "agg": {m: {str(s): agg[m][s] for s in agg[m]} for m in agg}}, indent=2, default=str))
    # drift note
    print("\nDrift on shared first-10 chats (replyability as batch grows 10->25->50):")
    for model in models:
        flips = sum(1 for cid, byz in drift[model].items()
                    if len({byz.get(s) for s in SIZES if s in byz}) > 1)
        print(f"  {model:24} chats that changed verdict with batch size: {flips}/10")


def main():
    mse.load_env()
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--db", default=str(Path.home() / "Library" / "Application Support" / "Pidgy" / "pidgy.db"))
    b.add_argument("--pools", type=int, default=2, help="how many independent 50-chat pools")
    b.add_argument("--window", type=int, default=6, help="messages per candidate chat")
    b.set_defaults(func=cmd_build)
    s = sub.add_parser("sweep")
    s.add_argument("--models", default="openai/gpt-5,openai/gpt-5-mini,qwen/qwen3.7-max")
    s.add_argument("--ref", default="openai/gpt-5")
    s.add_argument("--concurrency", type=int, default=4)
    s.set_defaults(func=cmd_sweep)
    args = p.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
