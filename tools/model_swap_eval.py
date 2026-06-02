#!/usr/bin/env python3
"""
model_swap_eval.py — Find the cheapest model that matches gpt-5's quality on
Pidgy's pipeline-triage prompt, using OpenRouter (one key, every model) and the
real production decisions already captured in the LangSmith `pidgy` project.

The question this answers: "Which is the cheapest (ideally US-based) model whose
on_me / on_them / quiet decisions agree with gpt-5 on real traffic?"

Method (see docs/model_swap_eval.md):
  1. build  — pull recent `pipelineTriage` traces from LangSmith. Each trace is a
              (real system prompt, real chat context) -> gpt-5 decision + cost. We
              treat gpt-5's decision as the reference and write a replay dataset.
              The trace IS the real prompt, so there is no prompt-drift risk.
  2. sweep  — replay every example through each candidate model via OpenRouter and
              score: category agreement with gpt-5 (overall + per class), the
              all-important on_me recall, valid-JSON rate, latency, and real cost
              (OpenRouter returns the actual $ per call). Optionally logs one
              LangSmith experiment per model so you get the side-by-side view.
  3. report — rank models cheapest-first and flag the cheapest one clearing the
              quality bar.

No post-hoc heuristics massage the model output: we parse the JSON the model
returns and compare it to gpt-5. If a model needs fixing, that is a prompt change,
not an eval hack.

Keys (read from the environment or a gitignored `.env.eval.local` at repo root):
  OPENROUTER_API_KEY   required for `models`, `sweep`
  LANGSMITH_API_KEY    required for `build` (and the optional --langsmith push)

Usage:
  python3 tools/model_swap_eval.py build  --limit 120 --per-class 40
  python3 tools/model_swap_eval.py models --max-price 5
  python3 tools/model_swap_eval.py sweep  --limit 5          # cheap smoke test
  python3 tools/model_swap_eval.py sweep  --models openai/gpt-5,openai/gpt-5.4-mini,google/gemini-2.5-flash-lite
  python3 tools/model_swap_eval.py report
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import textwrap
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Any, Optional

REPO_ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = REPO_ROOT / "tools" / "model_swap_eval_out"
DATASET_PATH = OUT_DIR / "pipeline_triage_replay.jsonl"
PIPELINE_PROMPT_SWIFT = REPO_ROOT / "Sources" / "AI" / "Prompts" / "PipelineCategoryPrompt.swift"

LANGSMITH_PROJECT = "pidgy"
PIPELINE_RUN_NAME = "pipelineTriage"
OPENROUTER_BASE = "https://openrouter.ai/api/v1"

# Decision categories the prompt can emit. (need_more is a separate status.)
CATEGORIES = ("on_me", "on_them", "quiet")

# Provider prefixes we treat as US-based. OpenRouter slugs are `provider/model`.
US_PREFIXES = (
    "openai/", "anthropic/", "google/", "meta-llama/", "amazon/",
    "x-ai/", "microsoft/", "nvidia/", "cohere/", "ai21/", "liquid/", "inflection/",
)
# Non-US providers — excluded from the default US sweep, flagged if explicitly asked.
NON_US_PREFIXES = (
    "deepseek/", "qwen/", "moonshotai/", "z-ai/", "minimax/", "01-ai/",
    "baidu/", "tencent/", "alibaba/", "mistralai/", "thudm/", "01.ai/",
)

# Curated default candidates: the strongest model each major (US) provider
# offers that is still cheaper than gpt-5 — a same-league, lower-price field, not
# the flyweight budget tier (no nano/mini-of-old-gen/lite/nova). Validated
# against live OpenRouter slugs at run time; anything missing is reported, never
# silently dropped. Incumbent first.
DEFAULT_CANDIDATES = [
    "openai/gpt-5",                   # incumbent / control
    "openai/gpt-5-mini",              # OpenAI    · ~5x cheaper
    "openai/gpt-5.4-mini",            # OpenAI    · newer mini
    "anthropic/claude-haiku-4.5",     # Anthropic · fastest current Claude
    "google/gemini-2.5-flash",        # Google
    "google/gemini-3-flash-preview",  # Google    · newer
    "x-ai/grok-4.3",                  # xAI
    "meta-llama/llama-4-maverick",    # Meta      · frontier MoE
]

# Markers for specialized (non-general-chat) variants we skip in --auto mode.
SPECIALIZED_MARKERS = ("image", "codex", "search", "audio", "tts", "embed",
                       "realtime", "vision", "whisper")


# ---------------------------------------------------------------------------
# Environment / keys
# ---------------------------------------------------------------------------
def load_env() -> None:
    """Load .env.eval.local then .env.eval from repo root into os.environ.
    Real environment variables always win over file values."""
    for name in (".env.eval.local", ".env.eval"):
        path = REPO_ROOT / name
        if not path.exists():
            continue
        for raw in path.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip().strip('"').strip("'")
            if key and key not in os.environ:
                os.environ[key] = value


def require_key(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        sys.exit(
            f"[error] {name} is not set.\n"
            f"  Put it in {REPO_ROOT / '.env.eval.local'} as a line like:\n"
            f"      {name}=...\n"
            f"  (that file is gitignored), or export it in your shell."
        )
    return value


# ---------------------------------------------------------------------------
# Prompt drift check
# ---------------------------------------------------------------------------
def swift_pipeline_prompt() -> Optional[str]:
    """Extract PipelineCategoryPrompt.systemPrompt from the Swift source so we
    can sanity-check that the traced prompt still matches what ships today."""
    if not PIPELINE_PROMPT_SWIFT.exists():
        return None
    text = PIPELINE_PROMPT_SWIFT.read_text(encoding="utf-8")
    m = re.search(r'static let systemPrompt = """\n(.*?)\n\s*"""', text, re.DOTALL)
    if not m:
        return None
    # Swift strips the leading indentation of a multiline literal at runtime;
    # mirror that with dedent so this matches the prompt the app actually sends.
    return textwrap.dedent(m.group(1))


# ---------------------------------------------------------------------------
# Decision parsing (shared by reference + candidates) — NO heuristics.
# ---------------------------------------------------------------------------
def parse_decision(text: Optional[str]) -> dict[str, Any]:
    """Parse one triage JSON object out of a model response.
    Returns {valid, status, category, urgency, suggestedAction}. valid=False when
    the response is missing/unparseable or the category is out of range."""
    out = {"valid": False, "status": None, "category": None, "urgency": None,
           "suggestedAction": None}
    if not text:
        return out
    obj = None
    try:
        obj = json.loads(text)
    except (json.JSONDecodeError, TypeError):
        # Tolerate prose around the JSON (some models wrap it) by grabbing the
        # first balanced object. This is parsing, not output-fixing.
        m = re.search(r"\{.*\}", text, re.DOTALL)
        if m:
            try:
                obj = json.loads(m.group(0))
            except json.JSONDecodeError:
                obj = None
    if not isinstance(obj, dict):
        return out
    status = obj.get("status")
    category = obj.get("category")
    out["status"] = status
    out["category"] = category
    out["urgency"] = obj.get("urgency")
    out["suggestedAction"] = obj.get("suggestedAction")
    # Valid = an in-range decision, or an explicit need_more.
    if status == "need_more":
        out["valid"] = True
    elif status == "decision" and category in CATEGORIES:
        out["valid"] = True
    elif category in CATEGORIES:  # some models omit status but give a category
        out["valid"] = True
        out["status"] = "decision"
    return out


# ---------------------------------------------------------------------------
# build — pull traces from LangSmith into a replay dataset
# ---------------------------------------------------------------------------
def cmd_build(args: argparse.Namespace) -> int:
    require_key("LANGSMITH_API_KEY")
    try:
        from langsmith import Client
    except ImportError:
        sys.exit("[error] `pip install langsmith` to build the dataset from traces.")

    client = Client(api_key=os.environ["LANGSMITH_API_KEY"])
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    print(f"[build] pulling up to {args.scan} '{PIPELINE_RUN_NAME}' runs from "
          f"project '{LANGSMITH_PROJECT}' ...")
    runs = client.list_runs(
        project_name=LANGSMITH_PROJECT,
        run_type="llm",
        filter=f'eq(name, "{PIPELINE_RUN_NAME}")',
        is_root=True,
        limit=args.scan,
    )

    swift_prompt = swift_pipeline_prompt()
    rows: list[dict[str, Any]] = []
    seen_systems: set[str] = set()
    drift_warned = False
    for run in runs:
        inputs = run.inputs or {}
        outputs = run.outputs or {}
        system = inputs.get("system")
        user = inputs.get("user")
        content = outputs.get("content")
        if not (system and user and content):
            continue
        ref = parse_decision(content)
        if not ref["valid"]:
            continue
        seen_systems.add(system)
        if swift_prompt and not drift_warned and swift_prompt[:200] not in system:
            print("[build] WARNING: traced system prompt does not match the current "
                  "Swift PipelineCategoryPrompt — you may be evaluating an older "
                  "prompt version. (Continuing with the traced prompt.)")
            drift_warned = True
        meta = (run.extra or {}).get("metadata", {}) if run.extra else {}
        latency = None
        if run.end_time and run.start_time:
            latency = (run.end_time - run.start_time).total_seconds()
        rows.append({
            "trace_id": str(run.id),
            "chat_id": meta.get("chat_id"),
            "system": system,
            "user": user,
            "ref_status": ref["status"],
            "ref_category": ref["category"],
            "ref_urgency": ref["urgency"],
            "gpt5_model": meta.get("model"),
            "gpt5_input_tokens": meta.get("input_tokens"),
            "gpt5_output_tokens": meta.get("output_tokens"),
            "gpt5_cost_usd": meta.get("cost_usd"),
            "gpt5_latency_s": latency,
        })

    if not rows:
        sys.exit("[build] no usable runs found.")

    if len(seen_systems) > 1:
        print(f"[build] note: {len(seen_systems)} distinct system prompts in the "
              f"window (prompt was edited during this period).")

    # Stratify so the easy `quiet` majority does not drown out on_me / on_them.
    by_class: dict[str, list[dict]] = {c: [] for c in CATEGORIES}
    need_more = []
    for r in rows:
        if r["ref_status"] == "need_more":
            need_more.append(r)
        elif r["ref_category"] in by_class:
            by_class[r["ref_category"]].append(r)

    selected: list[dict] = []
    for c in CATEGORIES:
        bucket = by_class[c]
        selected.extend(bucket[: args.per_class] if args.per_class else bucket)
    if args.include_need_more:
        selected.extend(need_more[: args.per_class] if args.per_class else need_more)
    if args.limit:
        selected = selected[: args.limit]

    with DATASET_PATH.open("w", encoding="utf-8") as f:
        for r in selected:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")

    print(f"[build] wrote {len(selected)} examples -> {DATASET_PATH}")
    dist = {c: sum(1 for r in selected if r["ref_category"] == c) for c in CATEGORIES}
    dist["need_more"] = sum(1 for r in selected if r["ref_status"] == "need_more")
    print(f"[build] class balance: {dist}")
    gpt5_costs = [r["gpt5_cost_usd"] for r in selected if r.get("gpt5_cost_usd")]
    if gpt5_costs:
        print(f"[build] gpt-5 baseline: ${sum(gpt5_costs)/len(gpt5_costs):.5f}/call "
              f"avg over {len(gpt5_costs)} traced calls")

    if args.push:
        _push_dataset_to_langsmith(client, selected, args.dataset_name)
    return 0


def _push_dataset_to_langsmith(client, rows: list[dict], dataset_name: str) -> None:
    """Create/replace a LangSmith dataset so `sweep --langsmith` can run experiments
    that show up in the comparison view."""
    print(f"[build] pushing {len(rows)} examples to LangSmith dataset '{dataset_name}' ...")
    try:
        if client.has_dataset(dataset_name=dataset_name):
            ds = client.read_dataset(dataset_name=dataset_name)
        else:
            ds = client.create_dataset(dataset_name=dataset_name,
                                       description="Pidgy pipelineTriage replay; "
                                                   "reference outputs are gpt-5 production decisions.")
        client.create_examples(
            dataset_id=ds.id,
            examples=[
                {"inputs": {"system": r["system"], "user": r["user"]},
                 "outputs": {"status": r["ref_status"], "category": r["ref_category"],
                             "urgency": r["ref_urgency"]}}
                for r in rows
            ],
        )
        print(f"[build] dataset ready: {dataset_name} ({ds.id})")
    except Exception as exc:  # noqa: BLE001 - surface but don't crash the build
        print(f"[build] LangSmith push failed (dataset still saved locally): {exc}")


# ---------------------------------------------------------------------------
# build-db — reconstruct the replay dataset straight from the local pidgy.db
# (no LangSmith key needed). Reference = the app's own cached gpt-5 decisions
# in pipeline_cache; inputs are rebuilt to match what gpt-5 saw (messages up to
# last_message_id, timestamps relative to analyzed_at).
# ---------------------------------------------------------------------------
TYPE_LABELS = {"user": "DM", "private": "DM", "self": "DM", "secret": "DM",
               "group": "Group", "supergroup": "Supergroup", "channel": "Channel"}
DM_TYPES = {"user", "private", "self", "secret"}


def _relative_ts(epoch: float, now: float) -> str:
    """Match the app's compact relative stamp seen in traces: 8h / 16m / 3d."""
    d = max(0, int(now - epoch))
    if d < 60:
        return f"{d}s"
    if d < 3600:
        return f"{d // 60}m"
    if d < 86400:
        return f"{d // 3600}h"
    if d < 7 * 86400:
        return f"{d // 86400}d"
    import datetime as _dt
    return _dt.datetime.fromtimestamp(epoch, _dt.timezone.utc).strftime("%b %d")


def _render_user(title: str, ctype: str, me_name: str, me_user: str,
                 msgs: list[dict]) -> str:
    """Reproduce PipelineCategoryPrompt.userMessage's exact wire format."""
    out = f'Chat: "{title}" ({TYPE_LABELS.get((ctype or "").lower(), (ctype or "DM").capitalize())})\n'
    out += f"You are: {me_name} (@{me_user})\n\n"
    out += f"Context window size: {len(msgs)} messages\n"
    # Present as the forced-decision retry pass: pipeline_cache only stores final
    # decisions, so we score the final category and avoid need_more confounds.
    out += "Retry pass: you MUST return status=decision.\n\n"
    out += "Messages in chronological order (oldest first):\n"
    for m in msgs:
        out += f"[messageId: {m['id']}] [{m['rel']}] {m['sender']}: {m['text']}\n"
    return out


def cmd_build_db(args: argparse.Namespace) -> int:
    import sqlite3
    db = Path(args.db).expanduser()
    if not db.exists():
        sys.exit(f"[build-db] DB not found: {db}")
    system = swift_pipeline_prompt()
    if not system:
        sys.exit("[build-db] could not read PipelineCategoryPrompt.swift")
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    conn = sqlite3.connect(str(db))
    conn.row_factory = sqlite3.Row

    me_name = args.me_name
    if not me_name:
        row = conn.execute(
            "SELECT sender_name, COUNT(*) c FROM messages WHERE is_outgoing=1 "
            "AND sender_name IS NOT NULL AND sender_name<>'' GROUP BY sender_name "
            "ORDER BY c DESC LIMIT 1").fetchone()
        me_name = row[0] if row else "Me"

    nodes = {str(r["entity_id"]): r for r in conn.execute(
        "SELECT entity_id, entity_type, display_name FROM nodes")}

    by_class: dict[str, list] = {c: [] for c in CATEGORIES}
    for r in conn.execute(
            "SELECT chat_id, category, last_message_id, analyzed_at "
            "FROM pipeline_cache ORDER BY analyzed_at DESC"):
        if r["category"] in CATEGORIES:
            by_class[r["category"]].append(r)

    rows_out = []
    skipped = 0
    for cat in CATEGORIES:
        bucket = by_class[cat][: args.per_class] if args.per_class else by_class[cat]
        for r in bucket:
            chat_id = str(r["chat_id"])
            node = nodes.get(chat_id)
            title = (node["display_name"] if node and node["display_name"]
                     else f"Chat {chat_id}")
            ctype = (node["entity_type"] if node else None) or \
                    ("Group" if chat_id.startswith("-") else "private")
            last_mid = int(r["last_message_id"]) if r["last_message_id"] else None
            now = float(r["analyzed_at"]) if r["analyzed_at"] else time.time()
            q = ("SELECT id, date, sender_name, is_outgoing, text_content "
                 "FROM messages WHERE chat_id=?")
            params: list = [int(r["chat_id"])]
            if last_mid is not None:
                q += " AND id <= ?"
                params.append(last_mid)
            q += " ORDER BY date DESC, id DESC LIMIT ?"
            params.append(args.window)
            mrows = list(reversed(conn.execute(q, params).fetchall()))
            if not mrows:
                skipped += 1
                continue
            is_dm = (ctype or "").lower() in DM_TYPES
            msgs = []
            for m in mrows:
                if int(m["is_outgoing"] or 0):
                    sender = "[ME]"
                else:  # for DMs the other party is the chat title; groups fall back to Unknown
                    sender = m["sender_name"] or (title if is_dm else "Unknown")
                text = " ".join((m["text_content"] or "").split()) or "[non-text message]"
                msgs.append({"id": m["id"], "rel": _relative_ts(float(m["date"]), now),
                             "sender": sender, "text": text})
            rows_out.append({
                "trace_id": f"cache-{chat_id}",
                "chat_id": chat_id,
                "system": system,
                "user": _render_user(title, ctype, me_name, args.me_username, msgs),
                "ref_status": "decision",
                "ref_category": cat,
                "ref_urgency": None,
                "gpt5_model": "gpt-5 (pipeline_cache)",
                "gpt5_cost_usd": None,
            })
    conn.close()

    if args.limit:
        rows_out = rows_out[: args.limit]
    with DATASET_PATH.open("w", encoding="utf-8") as f:
        for r in rows_out:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    dist = {c: sum(1 for r in rows_out if r["ref_category"] == c) for c in CATEGORIES}
    print(f"[build-db] wrote {len(rows_out)} examples -> {DATASET_PATH}")
    print(f"[build-db] class balance {dist}  (reference = pipeline_cache gpt-5 decisions)")
    print(f"[build-db] identity 'You are: {me_name} (@{args.me_username})'  "
          f"window={args.window} msgs  skipped(no msgs)={skipped}")
    return 0


# ---------------------------------------------------------------------------
# OpenRouter model catalog
# ---------------------------------------------------------------------------
def _http_json(url: str, headers: dict[str, str], body: Optional[dict] = None,
               timeout: int = 120) -> tuple[int, dict]:
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, headers=headers,
                                 method="POST" if data else "GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        try:
            payload = json.loads(e.read().decode("utf-8"))
        except Exception:  # noqa: BLE001
            payload = {"error": {"message": str(e)}}
        return e.code, payload
    except (urllib.error.URLError, OSError, TimeoutError) as e:
        # connection reset / DNS / timeout — surface as status 0 so the caller
        # retries instead of crashing the whole sweep.
        return 0, {"error": {"message": f"connection: {e}"}}
    except Exception as e:  # noqa: BLE001
        return -1, {"error": {"message": f"unexpected: {e}"}}


def openrouter_models() -> list[dict]:
    status, payload = _http_json(f"{OPENROUTER_BASE}/models", headers={})
    if status != 200:
        sys.exit(f"[error] OpenRouter /models returned {status}: {payload}")
    return payload.get("data", [])


def _price_per_mtok(model: dict) -> tuple[float, float]:
    pricing = model.get("pricing", {}) or {}
    prompt = float(pricing.get("prompt", 0) or 0) * 1_000_000
    completion = float(pricing.get("completion", 0) or 0) * 1_000_000
    return prompt, completion


def _is_text_chat(model: dict) -> bool:
    arch = model.get("architecture", {}) or {}
    modality = arch.get("modality", "") or ""
    # want text in -> text out; allow multimodal input as long as text output.
    return "text" in modality.split("->")[-1]


def cmd_models(args: argparse.Namespace) -> int:
    models = openrouter_models()
    rows = []
    for m in models:
        slug = m.get("id", "")
        if not _is_text_chat(m):
            continue
        us = slug.startswith(US_PREFIXES)
        if args.us_only and not us:
            continue
        p_in, p_out = _price_per_mtok(m)
        blended = p_in + p_out  # rough ordering proxy
        if args.max_price and blended > args.max_price * 2:
            continue
        rows.append((slug, us, p_in, p_out))
    rows.sort(key=lambda r: r[2] + r[3])
    print(f"{'model':52} {'US':>3} {'$in/Mtok':>10} {'$out/Mtok':>10}")
    print("-" * 80)
    for slug, us, p_in, p_out in rows:
        print(f"{slug:52} {'yes' if us else 'no ':>3} {p_in:10.3f} {p_out:10.3f}")
    print(f"\n{len(rows)} models listed. Pass slugs to `sweep --models a,b,c`.")
    return 0


def _looks_specialized(slug: str) -> bool:
    return any(mark in slug for mark in SPECIALIZED_MARKERS)


def select_default_models(incumbent: str = "openai/gpt-5", n: int = 8) -> list[str]:
    """Incumbent + the n cheapest US general-chat models priced below it."""
    models = {m["id"]: m for m in openrouter_models() if _is_text_chat(m)}
    inc = models.get(incumbent)
    inc_price = sum(_price_per_mtok(inc)) if inc else 1e9
    candidates = []
    for slug, m in models.items():
        if not slug.startswith(US_PREFIXES) or _looks_specialized(slug):
            continue
        price = sum(_price_per_mtok(m))
        if price < inc_price:
            candidates.append((price, slug))
    candidates.sort()
    chosen = [incumbent] if inc else []
    chosen += [slug for _, slug in candidates[:n]]
    return chosen


def resolve_candidates(wanted: list[str], incumbent: str) -> list[str]:
    """Keep only slugs OpenRouter actually serves right now; report any that are
    missing so the sweep never silently drops a model you asked for."""
    available = {m["id"] for m in openrouter_models()}
    present = [s for s in wanted if s in available]
    missing = [s for s in wanted if s not in available]
    if missing:
        print(f"[sweep] NOTE: {len(missing)} slug(s) not on OpenRouter right now, "
              f"skipping: {', '.join(missing)}")
    if incumbent in available and incumbent not in present:
        present.insert(0, incumbent)
    return present


# ---------------------------------------------------------------------------
# OpenRouter chat call (mirrors the app: response_format json + reasoning=low)
# ---------------------------------------------------------------------------
@dataclass
class CallResult:
    text: Optional[str] = None
    error: Optional[str] = None
    prompt_tokens: int = 0
    completion_tokens: int = 0
    cost_usd: float = 0.0
    latency_s: float = 0.0


def _post_with_retry(headers: dict, body: dict, tries: int = 4) -> tuple[int, dict, float]:
    """POST with backoff on transient rate-limit / server errors (429/5xx/408)."""
    delay = 2.0
    status, payload, latency = 0, {}, 0.0
    for attempt in range(tries):
        started = time.time()
        status, payload = _http_json(f"{OPENROUTER_BASE}/chat/completions",
                                     headers=headers, body=body)
        latency = time.time() - started
        if status in (0, 429, 408, 500, 502, 503, 529) and attempt < tries - 1:
            time.sleep(delay)
            delay *= 2
            continue
        break
    return status, payload, latency


def openrouter_chat(model: str, system: str, user: str, api_key: str,
                    max_tokens: int = 2048) -> CallResult:
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
        "HTTP-Referer": "https://github.com/pidgy/model_swap_eval",
        "X-Title": "Pidgy model-swap eval",
    }
    base_body = {
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "max_tokens": max_tokens,
        # Ask OpenRouter to return the real $ it billed for this call.
        "usage": {"include": True},
    }
    # Reasoning policy by model family:
    #  - OpenAI reasoning models mirror the app (effort=low).
    #  - Hybrid models (deepseek / qwen / glm / minimax / kimi) run in NON-thinking
    #    mode: for a fast JSON triage their long reasoning chains only add latency
    #    and cost (deepseek-v4-pro: 27s/$5.5 thinking vs 3.7s/$0.9 not) with no
    #    accuracy upside on this task.
    # Degrade gracefully for providers that reject either field — the prompt
    # itself also demands a single JSON object.
    if model.startswith(("deepseek/", "qwen/", "z-ai/", "minimax/", "moonshotai/")):
        reasoning = {"enabled": False}
    else:
        reasoning = {"effort": "low"}
    param_sets = (
        {"response_format": {"type": "json_object"}, "reasoning": reasoning},
        {"response_format": {"type": "json_object"}},
        {},
    )
    last = CallResult(error="unreachable")
    for params in param_sets:
        body = {**base_body, **params}
        status, payload, latency = _post_with_retry(headers, body)
        if status == 200:
            try:
                choice = payload["choices"][0]["message"]["content"]
            except (KeyError, IndexError, TypeError):
                return CallResult(error=f"no content: {json.dumps(payload)[:200]}",
                                  latency_s=latency)
            usage = payload.get("usage", {}) or {}
            return CallResult(
                text=choice,
                prompt_tokens=int(usage.get("prompt_tokens", 0) or 0),
                completion_tokens=int(usage.get("completion_tokens", 0) or 0),
                cost_usd=float(usage.get("cost", 0) or 0),
                latency_s=latency,
            )
        last = CallResult(error=f"http_{status}: {json.dumps(payload)[:300]}",
                          latency_s=latency)
        # Only a param rejection (400/422) is worth retrying with fewer params.
        if status not in (400, 422):
            break
    return last


# ---------------------------------------------------------------------------
# Scoring
# ---------------------------------------------------------------------------
@dataclass
class ModelSummary:
    model: str
    us: bool
    n: int = 0
    valid: int = 0
    decisions: int = 0
    category_agree: int = 0          # candidate.category == gpt-5.category (both decisions)
    urgency_agree: int = 0
    status_agree: int = 0
    # confusion + per-class, keyed by gpt-5 reference category
    ref_counts: dict = field(default_factory=lambda: {c: 0 for c in CATEGORIES})
    hit_counts: dict = field(default_factory=lambda: {c: 0 for c in CATEGORIES})  # agreed within class
    pred_counts: dict = field(default_factory=lambda: {c: 0 for c in CATEGORIES}) # candidate predicted class
    total_cost: float = 0.0
    total_latency: float = 0.0
    latencies: list = field(default_factory=list)
    errors: int = 0

    def add(self, ref: dict, pred: dict, cost: float, latency: float) -> None:
        self.n += 1
        self.total_cost += cost
        self.total_latency += latency
        self.latencies.append(latency)
        if pred.get("valid"):
            self.valid += 1
        ref_cat = ref["ref_category"]
        ref_status = ref["ref_status"]
        if pred.get("status") == ref_status:
            self.status_agree += 1
        # Per-class agreement only meaningful on decision rows.
        if ref_status == "decision" and ref_cat in CATEGORIES:
            self.decisions += 1
            self.ref_counts[ref_cat] += 1
            pc = pred.get("category")
            if pc in CATEGORIES:
                self.pred_counts[pc] += 1
            if pc == ref_cat:
                self.category_agree += 1
                self.hit_counts[ref_cat] += 1
            if pred.get("urgency") == ref["ref_urgency"]:
                self.urgency_agree += 1

    def recall(self, cat: str) -> Optional[float]:
        n = self.ref_counts[cat]
        return (self.hit_counts[cat] / n) if n else None

    def to_row(self, gpt5_cost_per_call: Optional[float]) -> dict:
        p50 = sorted(self.latencies)[len(self.latencies)//2] if self.latencies else 0.0
        cost_per_call = (self.total_cost / self.n) if self.n else 0.0
        return {
            "model": self.model,
            "us": self.us,
            "n": self.n,
            "valid_pct": round(100 * self.valid / self.n, 1) if self.n else 0,
            "category_agree_pct": round(100 * self.category_agree / self.decisions, 1) if self.decisions else 0,
            "on_me_recall_pct": round(100 * self.recall("on_me"), 1) if self.recall("on_me") is not None else None,
            "on_them_recall_pct": round(100 * self.recall("on_them"), 1) if self.recall("on_them") is not None else None,
            "quiet_recall_pct": round(100 * self.recall("quiet"), 1) if self.recall("quiet") is not None else None,
            "urgency_agree_pct": round(100 * self.urgency_agree / self.decisions, 1) if self.decisions else 0,
            "p50_latency_s": round(p50, 2),
            "cost_per_1k_usd": round(cost_per_call * 1000, 4),
            "vs_gpt5_cost": (round(cost_per_call / gpt5_cost_per_call, 3)
                             if gpt5_cost_per_call else None),
            "errors": self.errors,
        }


def load_dataset(limit: Optional[int]) -> list[dict]:
    if not DATASET_PATH.exists():
        sys.exit(f"[error] no dataset at {DATASET_PATH}. Run `build` first.")
    rows = [json.loads(l) for l in DATASET_PATH.read_text(encoding="utf-8").splitlines() if l.strip()]
    return rows[:limit] if limit else rows


def cmd_sweep(args: argparse.Namespace) -> int:
    api_key = require_key("OPENROUTER_API_KEY")
    rows = load_dataset(args.limit)
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    if args.models:
        models = resolve_candidates(
            [m.strip() for m in args.models.split(",") if m.strip()], args.incumbent)
    elif args.auto:
        print("[sweep] auto-selecting incumbent + cheapest US general-chat models ...")
        models = select_default_models(incumbent=args.incumbent, n=args.auto_n)
    else:
        print("[sweep] using curated default candidate set (override with --models or --auto)")
        models = resolve_candidates(DEFAULT_CANDIDATES, args.incumbent)
    if not models:
        sys.exit("[sweep] no candidate models resolved.")
    print(f"[sweep] {len(rows)} examples x {len(models)} models = {len(rows)*len(models)} calls")
    print(f"[sweep] models: {', '.join(models)}")

    gpt5_costs = [r["gpt5_cost_usd"] for r in rows if r.get("gpt5_cost_usd")]
    gpt5_cost_per_call = sum(gpt5_costs)/len(gpt5_costs) if gpt5_costs else None

    summary_objs: list[ModelSummary] = []
    for model in models:
        summary = ModelSummary(model=model, us=model.startswith(US_PREFIXES))
        preds_path = OUT_DIR / f"preds_{model.replace('/', '__')}.jsonl"
        pred_f = preds_path.open("w", encoding="utf-8")

        def work(row: dict) -> tuple[dict, CallResult]:
            res = openrouter_chat(model, row["system"], row["user"], api_key)
            return row, res

        print(f"\n[sweep] {model} ...")
        with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
            futures = [pool.submit(work, r) for r in rows]
            for i, fut in enumerate(as_completed(futures), 1):
                row, res = fut.result()
                if res.error:
                    summary.errors += 1
                    pred = {"valid": False}
                else:
                    pred = parse_decision(res.text)
                summary.add(row, pred, res.cost_usd, res.latency_s)
                pred_f.write(json.dumps({
                    "trace_id": row["trace_id"],
                    "chat_id": row.get("chat_id"),
                    "ref_category": row["ref_category"],
                    "ref_status": row["ref_status"],
                    "pred_category": pred.get("category"),
                    "pred_status": pred.get("status"),
                    "agree": pred.get("category") == row["ref_category"] and row["ref_status"] == "decision",
                    "valid": pred.get("valid", False),
                    "cost_usd": res.cost_usd,
                    "latency_s": round(res.latency_s, 2),
                    "error": res.error,
                    "raw": res.text,
                }, ensure_ascii=False) + "\n")
                if i % 10 == 0 or i == len(rows):
                    print(f"  {i}/{len(rows)}  agree={summary.category_agree}/{summary.decisions} "
                          f"valid={summary.valid} err={summary.errors}", flush=True)
        pred_f.close()
        summary_objs.append(summary)
        prog = summary.to_row(None)
        print(f"  -> cat≈gpt5={prog['category_agree_pct']}% "
              f"on_me_recall={prog['on_me_recall_pct']}% "
              f"valid={prog['valid_pct']}% ${prog['cost_per_1k_usd']}/1k")

    # Baseline = the incumbent's measured cost-per-call from this very sweep
    # (more accurate than any traced number, and works for the DB-built set).
    inc = next((s for s in summary_objs if s.model == args.incumbent), None)
    baseline = (inc.total_cost / inc.n) if (inc and inc.n and inc.total_cost) \
        else gpt5_cost_per_call
    summaries = [s.to_row(baseline) for s in summary_objs]
    summary_path = OUT_DIR / "summary.json"
    summary_path.write_text(json.dumps(
        {"gpt5_cost_per_call": baseline, "n_examples": len(rows),
         "models": summaries}, indent=2), encoding="utf-8")
    print(f"\n[sweep] wrote {summary_path}")
    _print_report(summaries, baseline, args)
    return 0


# ---------------------------------------------------------------------------
# report
# ---------------------------------------------------------------------------
def _print_report(summaries: list[dict], gpt5_cost_per_call: Optional[float],
                  args: argparse.Namespace) -> None:
    rows = sorted(summaries, key=lambda r: r["cost_per_1k_usd"])
    hdr = (f"{'model':40} {'US':>3} {'cat≈gpt5':>9} {'on_me_rec':>9} "
           f"{'valid':>6} {'p50_s':>6} {'$/1k':>9} {'xgpt5':>6}")
    print("\n" + "=" * len(hdr))
    print(hdr)
    print("-" * len(hdr))
    winner = None
    for r in rows:
        ok = (r["category_agree_pct"] >= args.min_agree
              and (r["on_me_recall_pct"] or 0) >= args.min_on_me_recall
              and r["valid_pct"] >= args.min_valid)
        flag = ""
        if ok and r["vs_gpt5_cost"] and r["vs_gpt5_cost"] < 1 and r["us"]:
            if winner is None:
                winner = r
                flag = "  <== cheapest US model clearing the bar"
        print(f"{r['model']:40} {'Y' if r['us'] else 'n':>3} "
              f"{r['category_agree_pct']:8.1f}% {str(r['on_me_recall_pct'])+'%':>9} "
              f"{str(r['valid_pct'])+'%':>6} {r['p50_latency_s']:6.2f} "
              f"{r['cost_per_1k_usd']:9.4f} {str(r['vs_gpt5_cost'])+'x':>6}{flag}")
    print("=" * len(hdr))
    print(f"bar: category agreement ≥{args.min_agree}%, on_me recall ≥{args.min_on_me_recall}%, "
          f"valid ≥{args.min_valid}%  |  gpt-5 baseline ${ (gpt5_cost_per_call or 0):.5f}/call")
    if winner:
        print(f"\nRECOMMENDATION: {winner['model']} — {winner['category_agree_pct']}% "
              f"agreement with gpt-5, {winner['on_me_recall_pct']}% on_me recall, "
              f"{winner['vs_gpt5_cost']}x the cost.")
    else:
        print("\nNo candidate cleared the bar — loosen thresholds or inspect "
              "preds_*.jsonl for where the cheap models diverge from gpt-5.")


def cmd_report(args: argparse.Namespace) -> int:
    summary_path = OUT_DIR / "summary.json"
    if not summary_path.exists():
        sys.exit(f"[error] no {summary_path}; run `sweep` first.")
    data = json.loads(summary_path.read_text(encoding="utf-8"))
    _print_report(data["models"], data.get("gpt5_cost_per_call"), args)
    return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def main() -> int:
    load_env()
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    b = sub.add_parser("build", help="pull pipelineTriage traces -> replay dataset")
    b.add_argument("--scan", type=int, default=400, help="how many recent runs to scan")
    b.add_argument("--per-class", type=int, default=40, help="max examples per category (stratify)")
    b.add_argument("--limit", type=int, default=0, help="hard cap on total examples (0=all)")
    b.add_argument("--include-need-more", action="store_true")
    b.add_argument("--push", action="store_true", help="also push to a LangSmith dataset")
    b.add_argument("--dataset-name", default="pidgy-pipeline-triage-replay")
    b.set_defaults(func=cmd_build)

    bd = sub.add_parser("build-db", help="build replay dataset from local pidgy.db (no LangSmith key needed)")
    bd.add_argument("--db", default=str(Path.home() / "Library" / "Application Support" / "Pidgy" / "pidgy.db"))
    bd.add_argument("--per-class", type=int, default=0, help="max examples per category (0=all available)")
    bd.add_argument("--limit", type=int, default=0, help="hard cap on total examples (0=all)")
    bd.add_argument("--window", type=int, default=12, help="messages of context per chat")
    bd.add_argument("--me-name", default="", help="your display name (default: inferred from outgoing msgs)")
    bd.add_argument("--me-username", default="pratzyy", help="your @username as it appears in the prompt")
    bd.set_defaults(func=cmd_build_db)

    m = sub.add_parser("models", help="list candidate models + live pricing")
    m.add_argument("--us-only", action="store_true", default=True)
    m.add_argument("--all-regions", dest="us_only", action="store_false")
    m.add_argument("--max-price", type=float, default=0, help="rough $/Mtok blended ceiling")
    m.set_defaults(func=cmd_models)

    s = sub.add_parser("sweep", help="run candidate models and score vs gpt-5")
    s.add_argument("--models", default="", help="comma-separated OpenRouter slugs (else curated default set)")
    s.add_argument("--incumbent", default="openai/gpt-5", help="reference model treated as ground truth")
    s.add_argument("--auto", action="store_true", help="auto-pick cheapest US chat models instead of curated set")
    s.add_argument("--auto-n", type=int, default=8, help="how many models to auto-pick with --auto")
    s.add_argument("--limit", type=int, default=0, help="cap examples (0=all). Use a small value to smoke-test.")
    s.add_argument("--concurrency", type=int, default=6)
    s.add_argument("--min-agree", type=float, default=90.0)
    s.add_argument("--min-on-me-recall", type=float, default=85.0)
    s.add_argument("--min-valid", type=float, default=99.0)
    s.set_defaults(func=cmd_sweep)

    r = sub.add_parser("report", help="re-print the ranked table from summary.json")
    r.add_argument("--min-agree", type=float, default=90.0)
    r.add_argument("--min-on-me-recall", type=float, default=85.0)
    r.add_argument("--min-valid", type=float, default=99.0)
    r.set_defaults(func=cmd_report)

    args = p.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
