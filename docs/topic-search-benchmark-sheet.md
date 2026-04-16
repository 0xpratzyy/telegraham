# Topic Search Benchmark Sheet

Last updated: 2026-04-12

This is the grounded final-answer benchmark for topic-search quality.

Canonical oracle:

- [topic_search_oracle_v1.json](/Users/pratyushrungta/telegraham/evals/topic_search_oracle_v1.json)
- [topic_search_oracle_v2.json](/Users/pratyushrungta/telegraham/evals/topic_search_oracle_v2.json)

Comparator script:

- [topic_search_answer_bench.py](/Users/pratyushrungta/telegraham/tools/topic_search_answer_bench.py)

Latest run artifacts:

- [report.json](/Users/pratyushrungta/Library/Application%20Support/Pidgy/debug/topic_search_bench/20260412-215224/report.json)
- [leaderboard.md](/Users/pratyushrungta/Library/Application%20Support/Pidgy/debug/topic_search_bench/20260412-215224/leaderboard.md)

## Goal

Move beyond routing-only checks and verify that topic search returns the right chats for concept-level queries.

This benchmark tests:

- whether the correct topic chat lands at the top
- whether the right chat still appears in the top 3 when the topic is noisier
- whether the surfaced snippet actually reflects the intended topic
- whether person-plus-topic traps correctly return no result instead of gluing unrelated chats together

## Coverage

The first grounded topic-search oracle includes `17` cases:

- `13` hit cases
- `4` strict no-result traps

It covers:

- First Dollar weekly updates
- builder program collaboration with Jack and Emma
- Huddle01 cloud / pricing discussion
- Inner Circle budget / office planning
- the BD hiring decision
- First Dollar overview
- Radar Room / platform gaps
- Twitter/X data options
- Skate deployment blocker
- hackathon rankings
- Paperclip team brief
- First Dollar marketplace strategy
- positive QA feedback on balance transfer / withdrawals
- strict person-topic no-result traps like Rahul + wallet addresses

The mined-from-local-data `v2` oracle keeps the no-result traps but replaces the hit side with more natural prompts drawn from your own corpus, including:

- `What's latest with First Dollar case studies?`
- `Show me discussions about Radar Room.`
- `What's latest with sub agents?`
- `Show me discussions about Claude Code.`
- `What's latest with OpenClaw gateway?`
- `What's latest with Inner Circle?`
- `Show me discussions about office space.`
- `Show me discussions about smart contracts.`
- `What's latest with proxy swap?`
- `What's latest with tweet ideas?`
- `Show me discussions about talent protocol.`
- `What's latest with screenshots and recordings?`
- `What's latest with API keys?`

## How To Run

```bash
/usr/bin/python3 /Users/pratyushrungta/telegraham/tools/topic_search_answer_bench.py
```

## Variants

Current script-only variants:

- `fts_rollup_v1`
  - FTS-heavy chat rollup
  - finds the right hit chats
  - weak on no-result traps
- `topic_guarded_v2`
  - adds stricter clue-coverage guards
  - still too willing to glue name + topic words across unrelated rows
- `topic_guarded_v3`
  - current winner
  - uses wider FTS candidate pools
  - narrows vector scoring to those candidate chats
  - adds stronger person-topic co-occurrence guards
  - treats no-result traps honestly instead of forcing a nearest chat

## Current Script-Only Results

| Variant | Top-1 | Top-3 | Snippet | Strict Pass | No Result |
| --- | ---: | ---: | ---: | ---: | ---: |
| `topic_guarded_v3` | `100.0%` | `100.0%` | `100.0%` | `100.0%` | `100.0%` |
| `fts_rollup_v1` | `100.0%` | `100.0%` | `100.0%` | `76.5%` | `0.0%` |
| `topic_guarded_v2` | `100.0%` | `100.0%` | `100.0%` | `76.5%` | `0.0%` |

## Current Recommendation

Use `topic_guarded_v3` as the benchmark winner for topic search.

Why:

- it keeps the strong hit retrieval of the simpler variants
- it fixes the main product risk: false-positive person-topic glue on no-result traps
- it now has a matching guarded product-side port in [SearchCoordinator.swift](/Users/pratyushrungta/telegraham/Sources/Views/SearchCoordinator.swift)

## Remaining Work

The current winner clears both `v1` and the more realistic mined `v2`, and the guarded scoring/coverage logic is now ported into the app. The next useful step is live dogfooding so any real misses can become new oracle cases.
