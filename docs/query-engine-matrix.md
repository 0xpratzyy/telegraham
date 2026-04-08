# Query Engine Matrix

Last updated: 2026-04-08

Pidgy should not force every query through one retrieval path. The product works best when we parse the user query into a **family**, then route it to the right **engine**.

## Families

| Family | Preferred engine | Example queries | Current status |
| --- | --- | --- | --- |
| `exact_lookup` | `message_lookup` | `where I shared wallet address`, `find message with contract address`, `where did I send this link` | Supported through `PatternSearchEngine`, still being tuned |
| `topic_search` | `semantic_retrieval` | `first dollar`, `partnership discussions`, `people asking about onboarding` | Supported |
| `reply_queue` | `reply_triage` | `who do I need to reply to`, `who is waiting on me`, `who haven't I replied to` | Supported through `ReplyQueueEngine`, still being tuned |
| `relationship` | `graph_crm` | `stale investors`, `top builders`, `who do I talk to most` | Recognized by router, intentionally unsupported in MVP runtime |
| `summary` | `summarize` | `summarize my chats with Akhil`, `what did we decide`, `what happened in this group` | Supported through `SummaryEngine`, still being tuned |

## Routing Principles

1. `exact_lookup` is about **literal presence**.
   - Best for wallet addresses, URLs, usernames, transaction hashes, contract addresses, and exact phrases.
   - Uses the dedicated `PatternSearchEngine` on top of the durable `messages` history table.

2. `topic_search` is about **meaning**.
   - Best for queries where exact words may vary.
   - Uses local FTS + vector retrieval + optional AI rerank.

3. `reply_queue` is about **responsibility**.
   - Best for `on_me / on_them / quiet` style inbox triage.
   - Should use chat classification first, then ranking.

4. `relationship` is about **people and graph state**.
   - Best for stale contacts, important people, categories, and CRM rollups.
   - Should eventually query graph tables directly instead of piggybacking on semantic search.

5. `summary` is about **synthesis after retrieval**.
   - Retrieve relevant messages first, then summarize.
   - Should not be treated as plain topic search.

## Storage Assumption

All current engines assume:

- `messages` is durable local history
- hot recent-message caching is memory-first
- normal cache refreshes must not trim SQLite history or reset `sync_state`

## Current Runtime Mapping

Until every engine is implemented, the runtime still falls back to the closest existing path:

| Preferred engine | Current runtime path |
| --- | --- |
| `message_lookup` | dedicated `PatternSearchEngine` |
| `semantic_retrieval` | `semantic_search` |
| `reply_triage` | dedicated `ReplyQueueEngine` for reply-queue queries |
| `graph_crm` | unsupported in MVP runtime |
| `summarize` | dedicated `SummaryEngine` |

## Priority Follow-Up Work

1. Improve `PatternSearchEngine` ranking and entity quality.
2. Tighten `ReplyQueueEngine` latency, batching, and quality.
3. Add graph-backed CRM execution for `relationship`.
4. Improve time-range-aware retrieval and summary quality.
