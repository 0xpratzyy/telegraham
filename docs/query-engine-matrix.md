# Query Engine Matrix

Last updated: 2026-07-21 (post context-layer refactor)

Pidgy does not force every query through one retrieval path. The interpreter
parses the query into a **family**; one shared routing table
(`QueryFamily.preferredEngine` in `Sources/AI/Models/AIModels.swift`) maps it
to an **engine**. The AI planner can reroute the family when confident; the
deterministic parse is the fallback.

## Families

| Family | Engine | Example queries | Runtime behavior |
| --- | --- | --- | --- |
| `exact_lookup` | `message_lookup` | `where I shared wallet address`, `where did I send this link` | `PatternSearchEngine` over the durable `messages` table |
| `topic_search` | `semantic_retrieval` | `first dollar`, `partnership discussions` | Local FTS variants + vectors, RRF-fused. **No AI call** — an LLM reranker was measured at +2 points end-to-end and removed, so search is instant and literal |
| `reply_queue` | `semantic_retrieval` | `who do I need to reply to`, `who is waiting on me` | **Ask Pidgy chat auto-opens** and answers from REPLY-kind open loops in the fact store; semantic ranking surfaces relevant chats underneath |
| `summary` — person question | `semantic_retrieval` | `what's the latest with Akhil?`, `akhil ke saath kya chal rha` | **Ask Pidgy chat auto-opens**; the fact-grounded answer card IS the summary (rolling summaries + open loops, ~1.5s) |
| `summary` — chat/topic recap | `summarize` | `summarize my chats with Akhil from last week`, `what did we decide` | `SummaryEngine` deep map-reduce recap |
| `relationship` | `graph_crm` | `stale investors`, `who do I talk to most` | Recognized by the router, intentionally unsupported at runtime |

`QuerySpec.isAnswerEngineQuestion` is the single definition of "the chat owns
this query" (reply-queue family + summary-family person questions) — shared by
the router and the launcher's auto-open so they can never disagree.

## Routing Principles

1. `exact_lookup` is about **literal presence** — wallet addresses, URLs,
   usernames, hashes, exact phrases.
2. `topic_search` is about **meaning** — exact words may vary.
3. `reply_queue` is about **responsibility** — answered from the context
   layer's open loops (`i_owe` reply-kind), not by re-scanning chats with AI.
   The retired agentic reply-triage engine used to re-classify chats per
   query; the fact store already knows.
4. `summary` is about **synthesis after retrieval** — person questions get
   the fast grounded answer; deep recaps run the retrieval-first engine.
5. `relationship` should eventually query graph tables directly.

## Storage Assumptions

- `messages` is durable local history; hot caching is memory-first.
- `facts` / `entity_summaries` are the derived store the answer surfaces read.
- `recent_sync_state` tracks freshness separately from deep indexing.
- Launcher queries read memory + SQLite; no inline Telegram fetches.

## Priority Follow-Up Work

1. Fix the SummaryEngine scoring regressions and re-enable their tests (#59).
2. Graceful reply-queue degraded mode when AI is off / memory engine killed (#64).
3. Add graph-backed CRM execution for `relationship`.
4. Improve time-range-aware retrieval quality.
