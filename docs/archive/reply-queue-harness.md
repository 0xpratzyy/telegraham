# Reply Queue Harness

Last updated: 2026-04-14

This is the offline benchmark loop for improving reply-queue quality without merging prompt experiments directly into the app.

## Goal

Use the saved reply-queue candidate snapshot plus the manual gold labels to compare prompt + digest variants on:

- latency
- cost
- strict precision / recall / F1
- lenient precision / recall / F1
- group-specific quality
- stability across repeated trials

## Main Files

- [reply_queue_variant_bench.py](/Users/pratyushrungta/telegraham/tools/reply_queue_variant_bench.py)
- [reply_queue_gold_eval.py](/Users/pratyushrungta/telegraham/tools/reply_queue_gold_eval.py)
- [reply_queue_candidate_diff.py](/Users/pratyushrungta/telegraham/tools/reply_queue_candidate_diff.py)
- [reply_queue_harness.py](/Users/pratyushrungta/telegraham/tools/reply_queue_harness.py)
- [reply_queue_manual_gold_mixed_recent_48.json](/Users/pratyushrungta/telegraham/evals/reply_queue_manual_gold_mixed_recent_48.json)
- [reply_queue_manual_oracle_v1.json](/Users/pratyushrungta/telegraham/evals/reply_queue_manual_oracle_v1.json)
- [reply_queue_group_precision_oracle_v1.json](/Users/pratyushrungta/telegraham/evals/reply_queue_group_precision_oracle_v1.json)
- [reply_queue_group_fp_traps_oracle_v1.json](/Users/pratyushrungta/telegraham/evals/reply_queue_group_fp_traps_oracle_v1.json)
- [reply-queue-variant-matrix.md](/Users/pratyushrungta/telegraham/docs/reply-queue-variant-matrix.md)

## Fast Usage

Run the full harness on selected variants:

```bash
/usr/bin/python3 /Users/pratyushrungta/telegraham/tools/reply_queue_harness.py \
  --variants baseline_compact_v1_4x12 field_aware_groups_v3_private_recall_v2_digest_v5_digest_v5_4x12 \
  --trials 2
```

Outputs go to:

- `~/Library/Application Support/Pidgy/debug/reply_queue_harness/<run-id>/report.json`
- `~/Library/Application Support/Pidgy/debug/reply_queue_harness/<run-id>/leaderboard.md`
- per-trial raw outputs under `trials/`

Run the broader oracle sweep:

```bash
/usr/bin/python3 /Users/pratyushrungta/telegraham/tools/reply_queue_oracle_bench.py \
  --variants baseline_compact_v1_4x12 field_aware_groups_v3_private_recall_v2_digest_v5_digest_v5_4x12 \
  --oracle /Users/pratyushrungta/telegraham/evals/reply_queue_manual_oracle_v1.json
```

Run the harsher Apr 12 group-focused oracle:

```bash
/usr/bin/python3 /Users/pratyushrungta/telegraham/tools/reply_queue_oracle_bench.py \
  --variants baseline_compact_v1_4x12 field_aware_groups_v3_private_recall_v2_digest_v5_digest_v5_4x12 \
  --oracle /Users/pratyushrungta/telegraham/evals/reply_queue_group_precision_oracle_v1.json
```

Run the older false-positive trap oracle:

```bash
/usr/bin/python3 /Users/pratyushrungta/telegraham/tools/reply_queue_oracle_bench.py \
  --variants field_aware_groups_v3_private_recall_v2_digest_v5_digest_v5_4x12 field_aware_groups_v3_private_recall_v2_digest_v5_digest_v6_4x12 \
  --oracle /Users/pratyushrungta/telegraham/evals/reply_queue_group_fp_traps_oracle_v1.json
```

## Recommended Workflow

1. Add or adjust a prompt/digest variant in [reply_queue_variant_bench.py](/Users/pratyushrungta/telegraham/tools/reply_queue_variant_bench.py).
2. Run the harness against the gold set.
3. Compare leaderboard metrics first.
4. Use [reply_queue_candidate_diff.py](/Users/pratyushrungta/telegraham/tools/reply_queue_candidate_diff.py) on the winner and runner-up to inspect false positives and misses.
5. Only then promote the winning variant into [ReplyQueueTriagePrompt.swift](/Users/pratyushrungta/telegraham/Sources/AI/Prompts/ReplyQueueTriagePrompt.swift).

## What To Optimize For

Default priority order:

1. overall strict F1
2. group lenient F1
3. latency

Why:

- reply queue must stay trustworthy
- groups are the main historical failure mode
- once quality is acceptable, latency decides product feel

## Notes

- Keep `gpt-5.4-mini` as the comparison baseline unless we are explicitly doing model exploration.
- Use the harness before app-path prompt changes.
- Treat the manual gold set as the benchmark reference, not raw model confidence.
- The bench scripts now auto-discover the provider-scoped OpenAI key at `~/Library/Application Support/Pidgy/credentials/com.pidgy.aiApiKey.openai`, so manual `--api-key-file` overrides should usually not be needed.
- Current research branch:
  - `digest_v6` widens group context and adds targeted fields for explanatory technical replies, cc-style mentions, and earlier requests for input
  - `field_aware_groups_v4_contextual_recovery_v1 + digest_v6` currently wins the fresh Apr 12 group oracle
  - `field_aware_groups_v3_private_recall_v2 + digest_v6` is the safer broad candidate so far across the older trap oracle and the broader multi-snapshot oracle
- Current tiered branch:
  - `field_aware_groups_v5_tiered_review_v1 + digest_v6` adds a benchmark-only `worth_checking` classification for stale-but-real open loops that should surface below true reply-now items
  - after closure-heuristic tuning for phrases like `Already added`, this branch now matches the human intuition on `Banko` better by surfacing it without promoting it to `on_me`, while suppressing older resolved group asks like `Bhavyam <> First Dollar`
  - the stricter `field_aware_groups_v6_tiered_review_v2 + digest_v6` experiment is useful as a stress test, but it over-corrects on fresh snapshots and is not the current recommendation
