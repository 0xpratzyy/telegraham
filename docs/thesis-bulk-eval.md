# Thesis Bulk Eval

Last updated: 2026-04-12

This is the bulk runner for the current MVP product theses.

It executes one consolidated suite and writes a single report folder with:

- unit-test gate status
- prompt-routing coverage across product phrasing families
- exact-lookup probe results
- topic-search FTS probe results
- reply-queue harness results when a valid OpenAI key is available
- explicit gaps where we still lack a direct harness

## Main Files

- [thesis_bulk_eval.py](/Users/pratyushrungta/telegraham/tools/thesis_bulk_eval.py)
- [thesis_eval_suite.json](/Users/pratyushrungta/telegraham/evals/thesis_eval_suite.json)
- [query_routing_probe.py](/Users/pratyushrungta/telegraham/tools/query_routing_probe.py)
- [product_prompt_oracle_v1.json](/Users/pratyushrungta/telegraham/evals/product_prompt_oracle_v1.json)
- [product_prompt_oracle_bench.py](/Users/pratyushrungta/telegraham/tools/product_prompt_oracle_bench.py)
- [exact_lookup_probe.py](/Users/pratyushrungta/telegraham/tools/exact_lookup_probe.py)
- [topic_search_probe.py](/Users/pratyushrungta/telegraham/tools/topic_search_probe.py)
- [reply_queue_harness.py](/Users/pratyushrungta/telegraham/tools/reply_queue_harness.py)

## Default Run

```bash
/usr/bin/python3 /Users/pratyushrungta/telegraham/tools/thesis_bulk_eval.py
```

Outputs go to:

- `~/Library/Application Support/Pidgy/debug/thesis_bulk_eval/<run-id>/report.json`
- `~/Library/Application Support/Pidgy/debug/thesis_bulk_eval/<run-id>/report.md`

## What It Measures Today

### Routing coverage

For each prompt family in the suite:

- runs many paraphrases through a scriptable routing probe
- checks whether each query lands in the expected family
- reports coverage by family instead of relying on one canonical example

This is the eval-first approximation to “all the prompts users may type” without pretending we can enumerate infinite language.

### Exact lookup

For each query in the suite:

- artifact keywords detected
- recipient keywords detected
- direct artifact+recipient hits in the same message
- same-chat overlap between artifact evidence and recipient evidence

### Topic search

For each query in the suite:

- local FTS message-hit count
- top chat rollups from local FTS hits

### Reply queue

If a valid OpenAI key is available:

- runs the configured variants and trials
- reports winner, latency, and F1 metrics

If a valid key is not available:

- the suite still succeeds
- reply queue is marked as an explicit error section in the report

## Credentials

Reply-queue harness uses:

1. `OPENAI_API_KEY` environment variable, if present
2. [com.pidgy.aiApiKey](/Users/pratyushrungta/Library/Application%20Support/Pidgy/credentials/com.pidgy.aiApiKey)
3. legacy fallback [com.tgsearch.aiApiKey](/Users/pratyushrungta/Library/Application%20Support/Pidgy/credentials/com.tgsearch.aiApiKey)

If all of those are empty or invalid, the reply-queue section will report an auth failure but the rest of the thesis suite will still complete.

## Current Gaps

Still not directly bulk-evaluated:

- summary query quality beyond the unit test gate

Routing now has a standalone scriptable probe, but summary still lacks a true bulk quality harness.

Those are intentionally reported as gaps instead of being silently ignored.
