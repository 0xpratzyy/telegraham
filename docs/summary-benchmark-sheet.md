# Summary Benchmark Sheet

Last updated: 2026-04-12

This is the grounded final-answer benchmark for summary quality.

Canonical oracles:

- [summary_oracle_v1.json](/Users/pratyushrungta/telegraham/evals/summary_oracle_v1.json)
- [summary_oracle_v2.json](/Users/pratyushrungta/telegraham/evals/summary_oracle_v2.json)

Comparator script:

- [summary_answer_bench.py](/Users/pratyushrungta/telegraham/tools/summary_answer_bench.py)

Latest run artifacts:

- [report.json](/Users/pratyushrungta/Library/Application%20Support/Pidgy/debug/summary_bench/20260412-155311/report.json)
- [leaderboard.md](/Users/pratyushrungta/Library/Application%20Support/Pidgy/debug/summary_bench/20260412-155311/leaderboard.md)

## Goal

Move beyond routing-only checks and verify that summary produces the right local recap for the right chat, with the right supporting evidence.

This benchmark tests:

- whether the correct focus chat is chosen
- whether the right supporting messages are gathered
- whether the resulting bounded summary contains the required facts
- whether obvious irrelevant/stale phrases stay out

## Coverage

We now use two grounded summary oracles:

- `v1`: `9` grounded cases
  - `8` hit cases
  - `1` strict no-result trap
- `v2`: `18` grounded cases
  - `14` hit cases
  - `4` strict no-result traps

The broader `v2` oracle now covers:

- relationship follow-up recap after a call
- external collaboration/program discussion recap
- analytical product/vendor conclusion recap
- bounded weekly project summary
- internal decision recap with budget and office details
- a crisp single-message decision summary
- a one-message product overview
- a product gaps / roadmap recap
- tooling-options recap
- product blocker/root-cause recap
- ranked-comparison recap
- team-status / blocked-work recap
- marketplace strategy note recap
- QA feedback recap
- several strict “should return no local summary” traps

## How To Run

```bash
/usr/bin/python3 /Users/pratyushrungta/telegraham/tools/summary_answer_bench.py
```

## Variants

Current script-only variants:

- `focus_chat_v1`
  - simple focus-chat scoring plus bounded extractive recap
- `focus_chat_v2`
  - adds light decision/summary phrase weighting
- `focus_chat_v3`
  - stronger clue coverage for chat selection
  - better support-message ranking
  - richer bounded recap assembly
- `focus_chat_v4`
  - safest current variant
  - penalizes fake cross-topic overlaps
  - expands around anchor hits to recover nearby decision context
  - uses stricter support-message filtering for the final recap

## What Good Looks Like

For a strong summary implementation, we want:

- high `focusTop1Accuracy`
- high `supportingCoverage`
- high `factCoverage`
- perfect `cleanOutputRate`
- strong `strictPassRate`

That gives us a real “final answer” benchmark before any app-side summary changes.

## Current Script-Only Results

Latest benchmark snapshot on the broader `v2` oracle:

| Variant | Focus Top-1 | Focus Top-3 | Supporting | Fact Coverage | Clean Output | Strict Pass |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `focus_chat_v4` | `100.0%` | `100.0%` | `100.0%` | `100.0%` | `100.0%` | `100.0%` |
| `focus_chat_v3` | `77.8%` | `77.8%` | `100.0%` | `83.3%` | `100.0%` | `38.9%` |
| `focus_chat_v1` | `77.8%` | `77.8%` | `100.0%` | `46.3%` | `100.0%` | `22.2%` |
| `focus_chat_v2` | `77.8%` | `77.8%` | `100.0%` | `46.3%` | `100.0%` | `22.2%` |

### Current Recommendation

Use `focus_chat_v4` as the script benchmark winner for summary for now.

Why:

- it clears the broader grounded `v2` oracle at `100%` across focus, support, fact coverage, cleanliness, and strict pass rate
- it fixes the “generic mentions beat the real recap chat” failure mode
- it recovers nearby decision context instead of only the exact matched row
- it rejects the current Rahul + wallet no-result trap instead of hallucinating a fake summary thread

### Remaining Work

The current winner now clears `v2`, so summary is in a much better place for product promotion. The next useful step is to keep adding real user recap queries whenever dogfooding exposes a new summary shape or failure mode.
