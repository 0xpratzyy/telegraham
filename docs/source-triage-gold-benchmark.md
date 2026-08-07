# Gmail and Slack Triage/Task Gold Benchmark

This benchmark measures the live product outcome, not only prompt parsing. A
missing actionable message is a false negative; an intentionally filtered
noise message is a correct ignore. Ingestion coverage is reported separately.

## Privacy boundary

- Keep real Gmail and Slack fixtures under `.private-evals/`.
- Store source message locators, labels, and short reviewer reasons only.
- Do not commit raw bodies, Slack context windows, OAuth material, or connector
  responses.
- Public fixtures in `evals/` must be sanitized or synthetic.

## Labels

- `ignore`: no work should appear in Pidgy.
- `reply`: Pratyush owes a conversational response.
- `task`: Pratyush owns concrete work beyond a simple response.
- `waiting`: another person owns the next step.

## Slack ownership and closure

- A direct `@Pratyush` mention in an actionable request creates personal
  ownership, including when multiple people are tagged.
- Another tagged assignee completing the same request does not close
  Pratyush's task. Keep it open until Pratyush completes, declines, is excused,
  or the request is explicitly superseded.
- When nobody is directly assigned or tagged, another person's completed work
  can close a shared request if the surrounding thread shows no remaining work
  for Pratyush.
- A mention alone is not enough when it is merely informational or `cc`-style;
  the containing message must make an actionable request.

An item is gold only when `review.status` is `approved`. Codex/LLM suggestions
remain `provisional` and are a silver audit until a human adjudicates them.

## Run

```bash
python3 tools/source_triage_gold_eval.py \
  --gold .private-evals/source_triage_task_gold.json
```

Use `--include-provisional` for an explicitly non-gold silver run. Add `--out`
to retain the detailed prediction and fact evidence locally.

## Required slices

Build at least 100 approved cases per source, stratified rather than sampled
only from the inbox head:

- 25 obvious noise/automation cases
- 25 direct reply cases
- 25 concrete tasks
- 15 waiting-on-them cases
- 10 lifecycle traps: answered, completed, superseded, repeated, or expired

For Slack, include DMs, group DMs, channels, mentions, and threads. For Gmail,
include human threads, automated action-required mail, repeated reminders,
calendar traffic, security/OTP, and marketing.

## Promotion gates

- actionable precision >= 90%
- actionable recall >= 85%
- task F1 >= 85%
- reply F1 >= 85%
- waiting F1 >= 80%
- stale-open rate <= 5%
- duplicate task rate <= 2%
- p95 source-to-Pidgy freshness <= 5 minutes

Do not tune prompts against provisional labels or promote a change that improves
classification while reducing ingestion coverage.
