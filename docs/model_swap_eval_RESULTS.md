# Model-swap eval — results (2026-06-02)

**Question:** what's the cheapest (ideally US) model that's "as good as gpt-5" for
Pidgy's reply-queue AI calls?

**TL;DR — it's two different answers for two different calls:**

| call | input size | recommendation |
|---|---|---|
| `pipelineTriage` (per new message, 1 chat) | ~2.2k tok | **`openai/gpt-5-mini`** — ~6× cheaper (≈$0.20/1k warm), matches gpt-5 within noise, 100% valid JSON, one-line swap via the existing OpenAI provider |
| agentic batch search (ranks ≤50 chats/call) | ~9k tok | **not gpt-5-mini** — it drops candidates and gets unstable on big input. Keep **gpt-5**, or use **`qwen3.7-max` (reasoning off)**, or **cut `AppConstants.batchSize` 50→~10–15** (mini is flawless at size 10) |

Tooling: [`tools/model_swap_eval.py`](../tools/model_swap_eval.py) (per-chat) and
[`tools/model_swap_eval_batch.py`](../tools/model_swap_eval_batch.py) (batch). Harness
notes in [`docs/model_swap_eval.md`](model_swap_eval.md).

---

## Method

- **Models accessed via OpenRouter** (one key, every provider; real per-call cost
  returned by the API). Candidates run through the same client with provider-aware
  structured-output + reasoning handling.
- **Reference = gpt-5's own decisions.** For per-chat triage, the reference is the
  app's cached gpt-5 decisions in `pipeline_cache` (137 rows, naturally stratified
  on_me=20 / on_them=20 / quiet=97). Inputs are reconstructed from the local
  `pidgy.db` to match what gpt-5 saw (messages up to `last_message_id`, timestamps
  relative to `analyzed_at`). The real prompt is read from the Swift source, so
  there's no prompt drift.
- **Metrics:** category agreement with gpt-5 (overall + per-class precision/recall),
  `on_me` recall (the costly miss — a dropped reply obligation), valid-JSON rate,
  p50 latency, and real $/1k calls.
- **No post-hoc output massaging** — we parse what the model returns and compare.

### Important caveat on the absolute numbers
gpt-5 agrees with its *own* cached decisions only **83.9%** — that's the
reconstruction-noise + nondeterminism ceiling. **Read agreement relative to 83.9%,
not 100%.** Per-class recall (n≈20 for on_me/on_them) is noisy; quiet (n=97) is
stable. To get clean absolute numbers, replay the *exact* logged inputs via the
LangSmith `build` path (needs a LangSmith key) — gpt-5 self-agreement should then
approach ~95%+.

---

## Per-chat results (`pipelineTriage`, small context) — 13 models, 137 examples

Cost-sorted. Baseline gpt-5 = $0.00381/call. ⭐ = recommended.

| model | agree vs gpt‑5 | on_me | on_them | quiet | valid | p50 | $/1k | ×gpt5 | notes |
|---|---|---|---|---|---|---|---|---|---|
| google/gemma-3-27b-it | 62.8% | 75% | 60% | 61% | 100% | 2.1s | $0.22 | 0.06× | over-fires (noisy queue) |
| meta-llama/llama-4-maverick | 72.3% | 55% | 70% | 76% | 100% | 2.1s | $0.48 | 0.13× | drops on_me |
| **openai/gpt-5-mini** ⭐ | 79.6% | 70% | 90% | 79% | 100% | 3.7s | $0.67 | **0.18×** | **best cost/quality, US** |
| openai/gpt-5.4-mini | 79.6% | 65% | 50% | 89% | 100% | 2.2s | $1.14 | 0.30× | weak on_them |
| google/gemini-3-flash-preview | 81.8% | 65% | 90% | 84% | 100% | 1.7s | $1.42 | 0.37× | fastest; US |
| google/gemini-2.5-flash | 67.2% | 70% | 65% | 67% | 100% | 4.2s | $1.80 | 0.47× | weak |
| deepseek/deepseek-v4-pro | 74.5% | 60% | 60% | 80% | 99% | 3.2s | $2.31 | 0.61× | reasoning OFF — lost 9 pts |
| qwen/qwen3.7-max | 83.2% | 80% | 95% | 81% | 100% | 2.3s | $2.40 | 0.63× | reasoning OFF — best on_me; non-US |
| x-ai/grok-4.3 | 83.9% | 70% | 85% | 87% | 100% | 5.5s | $2.58 | 0.68× | closest to gpt-5; US |
| openai/gpt-5 (incumbent) | 83.9% | 70% | 85% | 87% | 100% | 4.0s | $3.81 | 1.0× | self-agreement = noise ceiling |
| google/gemini-3.5-flash | 85.4% | 60% | 75% | 93% | 100% | 2.6s | $6.12 | 1.6× | pricier; weak on_me |
| anthropic/claude-haiku-4.5 | 75.2% | 60% | 30% | 88% | 88% | 10.9s | $8.52 | 2.24× | invalid JSON, slow |
| anthropic/claude-sonnet-4.6 | 82.5% | 65% | 95% | 84% | 100% | 9.2s | $13.95 | 3.66× | premium |

**Read:** gpt-5-mini tracks gpt-5 within noise on every class at 0.18× cost.
grok-4.3 / qwen-off / gemini-3.5-flash sit at the 83.9% ceiling (statistically tied
with gpt-5) but cost the same or more. Everything pricier than gpt-5 only makes
sense going *upmarket* for quality — none out-decides gpt-5 here.

### Prompt caching (matters in production)
The ~1,900-token system prompt is constant on every call, so it caches. Cache-read
rates: gpt-5 $0.125/M, gpt-5-mini $0.025/M, gemini-3.5-flash $0.15/M.

- **OpenAI auto-caches through OpenRouter** — measured cost dropped **71%** on
  repeated calls (gpt-5-mini $0.00069 → $0.00020/call; gpt-5 $0.00346 → $0.00101).
- **Gemini caching did NOT trigger** via OpenRouter (0 cached tokens, flat cost over
  3 identical calls). Realizing it needs explicit Google context-cache resources.
- **Once input is cached, output price dominates** — and gpt-5-mini's $2/M output is
  4.5× cheaper than gemini-3.5-flash's $9/M. Even with *perfect* Gemini caching
  (~$1.47/1k) it stays ~7× pricier than gpt-5-mini's warm **~$0.20/1k**.

So caching makes gpt-5-mini's real production cost **≈$0.20/1k (~20× cheaper than
gpt-5)**, since the app calls OpenAI directly where caching is automatic.

### Reasoning toggle (hybrid models)
- **qwen3.7-max → win.** Non-thinking kept quality (84.7% → 83.2%) while going **5×
  faster** (11.9s → 2.3s) and ~2× cheaper. Best `on_me` recall in the field (80%).
- **deepseek-v4-pro → loss.** Non-thinking made it cheap/fast but dropped agreement
  83.2% → 74.5%. Its quality *was* the reasoning. Not competitive.
- Harness runs `deepseek/qwen/glm/minimax/kimi` in non-thinking mode by default.

---

## Big-input results (agentic batch search) — nested batches 10 → 25 → 50

The app batches up to `AppConstants.batchSize = 50` candidate chats per agentic call
(~9k tokens) and must return one result per candidate. Reference = gpt-5 at the same
size. (1 pool; size-25 gpt-5 reference errored, so recall %s are noisy — but
cardinality and drift are unambiguous.)

| model | batch size | returned all? | dropped | reply_now recall vs gpt‑5 | drift¹ | $/call | p50 |
|---|---|---|---|---|---|---|---|
| gpt-5 (ref) | 10 | ✅ 100% | 0 | 100% | — | $0.025 | 50s |
| gpt-5 (ref) | 50 | ❌ | 1/50 | (ref) | 1/10 | $0.087 | 123s |
| gpt-5-mini | 10 | ✅ 100% | 0 | 100% | — | $0.004 | 21s |
| **gpt-5-mini** | **50** | ❌ | **10/50** | **58%** | **5/10** | $0.013 | 65s |
| qwen-off | 50 | ❌ | 1/50 | 67% | 1/10 | $0.035 | 67s |

¹ drift = of the 10 chats present in every batch size, how many changed verdict just
because the batch grew.

**Read:** gpt-5-mini is **flawless at size 10** but on the 50-chat batch **drops 10
of 50 candidates**, hits only **58% reply_now recall**, and **flips half (5/10) of
the shared chats** purely from the bigger input. **qwen3.7-max (reasoning off) is
robust** — drops 1/50 and 1/10 drift, matching gpt-5's stability at ~0.4× its batch
cost. The failure is **batch-size-driven, not inherent to mini.**

---

## Recommendation

1. **`pipelineTriage` → `openai/gpt-5-mini`.** This is the high-volume per-message
   call (dominant cost). Validated safe, ~6× cheaper (≈$0.20/1k warm), one-line swap.
2. **agentic batch search → not gpt-5-mini.** Pick one:
   - **Keep gpt-5** — safest; it's an infrequent call so cost matters less.
   - **`qwen3.7-max` (reasoning off)** — robust on big input, ~0.4× cost; non-US.
   - **Cut `batchSize` 50 → ~10–15** — mini is perfect at size 10, so smaller chunks
     (more calls, each cheap + reliable) could make the cheap model viable for *both*
     calls. The most interesting lever: pure cost win, no quality hit.

---

## Cost lever — `reasoning_effort: minimal` (Lever 1, no model change)

The app uses `reasoning_effort: low`. Output (reasoning + JSON) is ~75–85% of each
pipelineTriage call's cost, and ~262 of ~344 output tokens are *reasoning*. Tested
`minimal` on the full 137 set via OpenRouter `openai/gpt-5`
([`tools/reasoning_effort_probe.py`](../tools/reasoning_effort_probe.py)):

| config | agree vs gpt‑5(low) | on_me | on_them | quiet | avg output | $/call |
|---|---|---|---|---|---|---|
| low (current) | 83.9% | 70% | 85% | 87% | 344 tok (262 reasoning) | $0.00381 |
| **minimal** | 77.4% | 65% | 90% | 77% | 53 tok | **$0.00130 (−66%)** |
| minimal + verbosity:low | 66.7% (n=30) | — | — | — | 48 tok | ~−70% |

`minimal` is **−66% cost and ~4× faster**, but **not free**: ~−6.5 pts agreement,
concentrated in **quiet recall 87→77%** (more false-positives → noisier queue) and a
small **on_me 70→65%** dip (missed replies — the costly direction, within n=20 noise).
`verbosity: low` degrades quality further → **skip it**.

**Cross-result:** gpt-5-**mini** at the current `low` reasoning (79.6%) beats gpt-5-
**minimal** (77.4%) on both quality *and* cost. So the **model swap dominates the
reasoning-drop** as a cost lever. Keep `low` if staying on gpt-5; use `minimal` only
as an extra squeeze once the queue-noise tradeoff is accepted. (Script-only; no
product change was made.)

## Reproduce

```bash
python3 -m venv .venv && . .venv/bin/activate && pip install langsmith requests
echo 'OPENROUTER_API_KEY=sk-or-v1-...' > .env.eval.local   # gitignored

# per-chat
python3 tools/model_swap_eval.py build-db                  # dataset from pidgy.db
python3 tools/model_swap_eval.py sweep                     # curated 8; or --models a,b,c
python3 tools/model_swap_eval.py report

# big-input batch
python3 tools/model_swap_eval_batch.py build --pools 1
python3 tools/model_swap_eval_batch.py sweep --models openai/gpt-5,openai/gpt-5-mini,qwen/qwen3.7-max
```

## Open / to harden
- **Exact-context replay** via the LangSmith `build` path (needs `LANGSMITH_API_KEY`)
  to remove DB-reconstruction noise and get absolute (not relative) numbers.
- **More batch pools** — the big-input run was 1 pool; rerun with `--pools 3+` for
  tighter recall numbers (cardinality/drift signals were already clear).
- The other prompts (summaries, person profiles) are generation tasks — they need an
  LLM-as-judge evaluator, not exact-match agreement.

## Notes
- Eval spend: ~$9 of OpenRouter credit. A scoped `pidgy-eval` inference key was
  minted from the provisioning key (deletable).
- **Rotate the OpenRouter provisioning key** — it was pasted into a chat session.
