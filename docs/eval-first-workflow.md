# Eval-First Workflow

Last updated: 2026-04-11

We should prefer offline/scripted evaluation before promoting search or ranking behavior into the live product.

## Rule

For search and reply-quality changes:

1. test the behavior with scripts or automated fixtures first
2. compare against the current baseline
3. only then promote the winner into the app path

This keeps us from discovering basic regressions through the live launcher UI.

## Reply Queue

Use the existing harness first:

- [reply_queue_harness.py](/Users/pratyushrungta/telegraham/tools/reply_queue_harness.py)
- [reply-queue-harness.md](/Users/pratyushrungta/telegraham/docs/reply-queue-harness.md)

This is the required loop for prompt/digest work:

1. add or edit the variant in [reply_queue_variant_bench.py](/Users/pratyushrungta/telegraham/tools/reply_queue_variant_bench.py)
2. run the harness against the gold set
3. inspect leaderboard + false positives/misses
4. only then promote the variant into [ReplyQueueTriagePrompt.swift](/Users/pratyushrungta/telegraham/Sources/AI/Prompts/ReplyQueueTriagePrompt.swift)

## Exact Lookup

Use both:

1. automated unit tests in [PidgyCoreTests.swift](/Users/pratyushrungta/telegraham/Tests/PidgyCoreTests.swift)
2. local evidence probe in [exact_lookup_probe.py](/Users/pratyushrungta/telegraham/tools/exact_lookup_probe.py)

### Why the probe exists

Before changing ranking/product behavior, we should be able to answer:

- does local SQLite even contain a true exact candidate?
- are we missing a real match, or is the query just too broad for exact lookup?

### Example

```bash
/usr/bin/python3 /Users/pratyushrungta/telegraham/tools/exact_lookup_probe.py "wallet I sent to Rahul"
```

This prints:

- artifact keywords
- recipient keywords
- direct artifact+recipient hits in the same message
- same-chat overlap between artifact evidence and recipient evidence
- representative local snippets

## Promotion Rule

Do not promote a search/ranking change into product unless at least one of these is true:

- it improves the relevant harness/fixture score
- it fixes a real failing regression test
- the offline evidence probe shows a product bug rather than a missing-data case

## Current Principle

- reply queue: harness first
- exact lookup: tests + local evidence probe first
- launcher UI: last step, not the first debugging tool

## Bulk MVP Thesis Run

Use [thesis_bulk_eval.py](/Users/pratyushrungta/telegraham/tools/thesis_bulk_eval.py) when we want one consolidated run across the current MVP theses.

This is the right command when we want to ask:

- how are the core theses doing together right now?
- which thesis has a real harness?
- which thesis still only has tests or a gap marker?

Default command:

```bash
/usr/bin/python3 /Users/pratyushrungta/telegraham/tools/thesis_bulk_eval.py
```

Reference:

- [Thesis Bulk Eval](/Users/pratyushrungta/telegraham/docs/thesis-bulk-eval.md)
