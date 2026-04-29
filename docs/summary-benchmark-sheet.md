# Summary Benchmark Sheet

Last updated: 2026-04-19

This is the grounded final-answer benchmark for summary quality.

Canonical oracles:

- [summary_oracle_v1.json](/Users/pratyushrungta/telegraham/evals/summary_oracle_v1.json)
- [summary_oracle_v2.json](/Users/pratyushrungta/telegraham/evals/summary_oracle_v2.json)
- [summary_oracle_v3.json](/Users/pratyushrungta/telegraham/evals/summary_oracle_v3.json)

Comparator script:

- [summary_answer_bench.py](/Users/pratyushrungta/telegraham/tools/summary_answer_bench.py)

Latest run artifacts:

- [report.json](/Users/pratyushrungta/Library/Application%20Support/Pidgy/debug/summary_bench/20260416-204200/report.json)
- [report.json](/Users/pratyushrungta/Library/Application%20Support/Pidgy/debug/summary_bench/20260419-171900/report.json)

## Goal

Move beyond routing-only checks and verify that summary produces the right local recap for the right chat, with the right supporting evidence.

This benchmark tests:

- whether the correct focus chat is chosen
- whether the right supporting messages are gathered
- whether the resulting bounded summary contains the required facts
- whether obvious irrelevant/stale phrases stay out

## Coverage

We now use three grounded summary oracles:

- `v1`: `9` grounded cases
  - `8` hit cases
  - `1` strict no-result trap
- `v2`: `23` grounded cases
  - `19` hit cases
  - `4` strict no-result traps
- `v3`: `50` grounded cases
  - `41` hit cases
  - `9` strict no-result traps

The broader `v3` oracle now covers:

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
- person-scoped recap prompt-family coverage for Akhil-style phrasings (`with Akhil`, `chat with Akhil`, `catch me up on Akhil`, `what did Akhil and I discuss`)
- heavier person-scoped recap stability coverage for Akhil-style prompts (`recent Akhil chats`, `latest with Akhil`, `recent Akhil conversation`, `last-week recap for Akhil`)
- alternate phrasing coverage for grounded hits like Inaara follow-up, Jack/Emma builder program recap, Huddle01 conclusion, First Dollar weekly recap, Inner Circle budget/office decisions, Skate blocker notes, and Paperclip team briefs
- several strict “should return no local summary” traps
- stricter person/topic no-result traps like `Sophia and wallet addresses` and `last week with Sophia`

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
  - current strongest overall variant
  - penalizes fake cross-topic overlaps
  - expands around anchor hits to recover nearby decision context
  - uses stricter support-message filtering for the final recap
- `focus_chat_v5`
  - adds stronger sender/scoped fallback for person-scoped recap queries
- `focus_chat_v6`
  - stricter person-scoped recap experiment

## What Good Looks Like

For a strong summary implementation, we want:

- high `focusTop1Accuracy`
- high `supportingCoverage`
- high `factCoverage`
- perfect `cleanOutputRate`
- strong `strictPassRate`

That gives us a real “final answer” benchmark before any app-side summary changes.

## Current Script-Only Results

Latest benchmark snapshot on the harder `v3` oracle:

| Variant | Focus Top-1 | Focus Top-3 | Supporting | Fact Coverage | Clean Output | Strict Pass |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `focus_chat_v4` | `70.0%` | `74.0%` | `74.0%` | `74.8%` | `100.0%` | `70.0%` |
| `focus_chat_v5` | `62.0%` | `74.0%` | `80.0%` | `81.0%` | `100.0%` | `62.0%` |
| `focus_chat_v3` | `52.0%` | `52.0%` | `70.0%` | `58.5%` | `100.0%` | `24.0%` |
| `focus_chat_v6` | `60.0%` | `60.0%` | `78.0%` | `39.5%` | `100.0%` | `20.0%` |
| `focus_chat_v1` | `52.0%` | `52.0%` | `70.0%` | `31.3%` | `100.0%` | `12.0%` |
| `focus_chat_v2` | `52.0%` | `52.0%` | `70.0%` | `31.3%` | `100.0%` | `12.0%` |

### Current Recommendation

Use `focus_chat_v4` as the current script benchmark winner for summary for now, but treat person-scoped recap focus as an active blocker rather than “solved.”

Why:

- it is still the strongest overall variant on the harder oracle
- it keeps clean output while the expanded person-scoped prompt family exposes the remaining ranking hole
- it recovers nearby decision context instead of only the exact matched row
- it still rejects the current Rahul + wallet no-result trap instead of hallucinating a fake summary thread

### Remaining Work

The new `v3` oracle shows that summary is still brittle for person-scoped recap prompts and a couple of collaboration-thread recaps. The main misses are:

- Akhil-style recap variants like `recent Akhil chats`, `latest with Akhil`, `recent Akhil conversation`, and `what has Akhil and I been talking about lately?`
- the Jack/Emma builder-program recap family
- a couple of stricter no-result traps like `Sophia and wallet addresses`

The next useful steps are:

- fix the chat focus ranking so stray group mentions of a person do not beat the real recap chat
- tighten scoped-person no-result handling so unrelated name matches do not produce fake summaries
- revisit the Jack/Emma builder-program case, which still collapses onto a strong but wrong project chat
- keep adding real user recap phrasings whenever dogfooding exposes a new summary shape or failure mode
- revisit whether person-scoped recap should stay single-chat or become bounded multi-chat synthesis for MVP
