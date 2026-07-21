# Model-swap eval — cheapest model that matches gpt-5

`tools/model_swap_eval.py` answers one question: **which is the cheapest (ideally
US-based) model whose pipeline-triage decisions agree with gpt-5 on our real
traffic?** It exists so we can move off `gpt-5` for the high-volume
`pipelineTriage` call without regressing the Reply Queue.

## Why this design

- **Reference = gpt-5's own production decisions.** Every `pipelineTriage` LLM
  call is already traced to LangSmith (`pidgy` project) as
  `(system prompt, chat context) -> {category, urgency, ...}`. We replay those
  exact inputs through each candidate and measure agreement with gpt-5. No
  hand-labeling, and the trace *is* the real prompt, so there's no prompt drift.
- **Per-class, not just overall.** Real traffic is ~75% `quiet`, so a model that
  always says `quiet` would score ~75% "accuracy". We report per-class
  precision/recall and headline **`on_me` recall** — missing an `on_me` means a
  dropped reply obligation, the failure a user actually feels.
- **Cost is exact.** OpenRouter returns the real `$` it billed per call; we don't
  estimate from a price table.
- **No output massaging.** We parse the JSON the model returns and compare it to
  gpt-5. If a cheap model is wrong, that's a prompt problem, not an eval hack.

## Setup

One gitignored file at the repo root, `.env.eval.local`:

```
OPENROUTER_API_KEY=sk-or-...
LANGSMITH_API_KEY=lsv2_...     # only needed for `build` + the optional --langsmith push
```

Python env (Python 3.12+; `langsmith` only needed for `build`):

```
python3 -m venv .venv && . .venv/bin/activate
pip install langsmith requests
```

## Workflow

```bash
# 1. Build a stratified replay dataset from recent gpt-5 traces.
python3 tools/model_swap_eval.py build --scan 400 --per-class 40

# 2. (optional) See the live US candidate lineup + pricing.
python3 tools/model_swap_eval.py models --us-only

# 3. Smoke test on 5 examples (a few cents) before the full run.
python3 tools/model_swap_eval.py sweep --limit 5

# 4. Full sweep over the curated US candidate set.
python3 tools/model_swap_eval.py sweep
#   --models openai/gpt-5,openai/gpt-5-mini,google/gemini-2.5-flash-lite   # explicit set
#   --auto --auto-n 10                                                     # cheapest-N US auto-pick
#   --langsmith                                                            # also log experiments for the comparison view

# 5. Re-print / re-threshold the ranked table without re-running.
python3 tools/model_swap_eval.py report --min-on-me-recall 90
```

## Reading the output

The ranked table (cheapest first) shows, per model: `cat≈gpt5` (overall category
agreement), `on_me_rec` (the key safety metric), `valid` (JSON-parse rate),
`p50_s` latency, `$/1k` calls, and `xgpt5` (cost relative to gpt-5). The
**cheapest US model clearing the bar** is flagged. Defaults for the bar:
category agreement ≥90%, `on_me` recall ≥85%, valid ≥99% — tune with the
`--min-*` flags.

Per-call predictions land in `tools/model_swap_eval_out/preds_<model>.jsonl`
(gitignored) so you can inspect exactly where a cheap model diverges from gpt-5.

## Scope / next steps

- v1 covers the `pipelineTriage` prompt only — the highest-volume call and the
  clearest to score. The same harness generalizes to the other prompts
  (`agenticSearch`, summaries, profiles) by adding their run-name + an evaluator;
  the generation ones need an LLM-as-judge rather than exact-match agreement.
- Agreement-with-gpt-5 measures "behaves like gpt-5", which assumes gpt-5 is
  right. To catch cases where a cheaper model is actually *better*, spot-check
  disagreements in `preds_*.jsonl`, or add the gold oracle sets in `evals/` as a
  second evaluator.
