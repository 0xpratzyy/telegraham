# Eval-First Workflow

Last updated: 2026-07-21

Prefer offline/scripted evaluation before promoting search, ranking, or
prompt behavior into the live product.

## Rule

For search, answer, and extraction-quality changes:

1. test the behavior with scripts or automated fixtures first
2. compare against the current baseline
3. only then promote the winner into the app path

This keeps us from discovering basic regressions through the live launcher
UI. Corollary from the fact-extraction work: **fix AI mistakes in the
prompt** — never with post-AI regex/keyword/count heuristics, and never with
an LLM judge cleaning up another LLM's output.

## Current harnesses

Oracles live in `evals/`, runners in `tools/`:

| Area | Oracle(s) | Runner |
|---|---|---|
| Exact lookup | `exact_lookup_oracle_v*.json` | `tools/exact_lookup_answer_bench.py`, probe: `tools/exact_lookup_probe.py` |
| Topic search | `topic_search_oracle_v*.json` | `tools/topic_search_answer_bench.py`, probe: `tools/topic_search_probe.py` |
| Summary | `summary_oracle_v*.json` | `tools/summary_answer_bench.py` |
| Query routing | — | `tools/query_routing_bench.py` / `query_routing_probe.py` |
| Prompt injection | `prompt_injection_oracle_v1.json` | `tools/prompt_injection_eval.py` |
| Gmail/Slack triage + tasks | private `.private-evals/` fixtures; sanitized schema in `source_triage_task_gold_template_v1.json` | `tools/source_triage_gold_eval.py` |
| Model swaps | — | `tools/model_swap_eval.py` (replays LangSmith traces; see archive for past results) |
| Everything at once | `thesis_eval_suite.json` | `tools/thesis_bulk_eval.py` |

Planner / embedding diagnostics also run as env-gated tests:
`TEST_RUNNER_PIDGY_PLANNER_DIAG=1` (and the embedding equivalent) against
the normal test target.

## Retired harnesses

The reply-queue triage harness family (`reply_queue_*` oracles and runners)
benchmarked the deleted per-query AI triage engine. The reply queue is now a
deterministic projection of the fact store — its correctness is covered by
unit tests (structural close, lane routing, answer-payload parity), not a
prompt harness. The old sheets live in [archive/](archive/). The oracles are
kept in `evals/` for provenance; don't spend model calls re-running them.

The source triage/task harness is different: it scores the current fact-store
projection end to end, including missing ingestion and stale open facts. Real
Gmail/Slack locators and reviewer labels stay gitignored under
`.private-evals/`; only approved human labels count as gold.

## Promotion Rule

Do not promote a search/ranking/prompt change unless at least one is true:

- it improves the relevant harness/oracle score
- it fixes a real failing regression test
- the offline evidence probe shows a product bug rather than a missing-data
  case

## Current Principle

- extraction & answers: oracle bench first, prompt-only fixes
- exact lookup / topic search: tests + probes first
- launcher UI: last step, not the first debugging tool
