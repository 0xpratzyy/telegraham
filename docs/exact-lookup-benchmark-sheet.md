# Exact Lookup Benchmark Sheet

Last updated: 2026-04-12

This is the grounded final-answer benchmark for exact lookup.

Canonical oracle:

- [exact_lookup_oracle_v1.json](/Users/pratyushrungta/telegraham/evals/exact_lookup_oracle_v1.json)
- [exact_lookup_oracle_v2.json](/Users/pratyushrungta/telegraham/evals/exact_lookup_oracle_v2.json)

Comparator script:

- [exact_lookup_answer_bench.py](/Users/pratyushrungta/telegraham/tools/exact_lookup_answer_bench.py)

## Goal

Move beyond routing-only checks and verify that exact lookup actually surfaces the right local chat/message evidence.

This benchmark tests:

- whether the top exact result is correct
- whether the right answer appears within the top 3
- whether strict no-result cases stay empty

## Coverage

We now use two grounded exact-lookup oracles:

- `v1`: `14` queries
  - `12` grounded hit cases
  - `2` grounded no-result cases
- `v2`: `37` queries
  - `33` grounded hit cases
  - `4` grounded no-result cases

The broader `v2` oracle is tied to real message IDs in local SQLite and now covers:

- `docs.firstdollar.money` root and `case-studies`
- First Dollar builder-program and product-spec Notion docs
- `app.firstdollar.money` admin / radar-room URLs
- GitHub repos, gists, X links, YouTube links, and Google Meet links
- exact handles like `@jackdishman`, `@Inaaralakhani`, `@abhitejsingh`
- exact emails like `mehtab@cypherblocks.xyz`, `team@firstdollar.money`, `prisha@0xfbi.com`
- exact wallet / contract / BaseScan / CA lookups
- stricter synthetic no-result traps for URLs, GitHub repos, and Meet codes

## How To Run

```bash
/usr/bin/python3 /Users/pratyushrungta/telegraham/tools/exact_lookup_answer_bench.py
```

## Variants

Current script-only variants:

- `baseline_v1`
  - loose keyword + structured-token ranking
- `artifact_ranked_v1`
  - stronger artifact-first scoring
  - better outgoing bias
  - phrase-aware ranking
  - stricter no-result thresholding

## What Good Looks Like

For a strong exact-lookup implementation, we want:

- high `top1Accuracy`
- near-perfect `top3Accuracy`
- perfect `noResultCoverage`

That gives us a clean “final answer” benchmark before any app-side changes.

## Current Script-Only Results

Latest benchmark snapshot:

| Variant | Top-1 | Top-3 | No-result coverage | Notes |
| --- | ---: | ---: | ---: | --- |
| `baseline_guarded_v1` | `100%` | `100%` | `100%` | Ties for best on the broader grounded `v2` oracle. |
| `baseline_guarded_v3` | `100%` | `100%` | `100%` | Ties for best on the broader grounded `v2` oracle and stays the preferred guarded script variant. |
| `baseline_guarded_v2` | `94.6%` | `94.6%` | `100%` | Strong, but no longer the top tier. |
| `artifact_ranked_v3` | `94.6%` | `94.6%` | `100%` | Better than the older artifact-first variants, but still behind the guarded winners. |
| `baseline_v1` | `91.9%` | `91.9%` | `100%` | Respectable now, but still less controlled than the guarded variants. |
| `artifact_ranked_v2` | `83.8%` | `91.9%` | `100%` | Useful stress comparator, not the winner. |
| `artifact_ranked_v1` | `83.8%` | `83.8%` | `0%` | Still too brittle on strict no-result cases. |

### Current Recommendation

Use `baseline_guarded_v3` as the exact-lookup script benchmark winner for now.

Why:

- it now clears the broader grounded `v2` oracle at `100% / 100% / 100%`
- it fixes the dangerous false-positive no-result behavior
- it handles emails, bare repo paths, Meet codes, BaseScan links, and clue-heavy natural-language exact queries correctly
- it is still script-only, which keeps us aligned with the eval-first workflow before any app-side promotion

### Remaining Misses

The current winner clears both `v1` and `v2`. The next useful step is not “promote blindly,” but to keep expanding the oracle whenever real user exact queries expose new retrieval shapes or ranking failures.
