# Query Engine Matrix

Pidgy should not force every query through one retrieval path. The product works best when we parse the user query into a **family**, then route it to the right **engine**.

## Families

| Family | Preferred engine | Example queries | Current status |
| --- | --- | --- | --- |
| `exact_lookup` | `message_lookup` | `where I shared wallet address`, `find message with contract address`, `where did I send this link` | Partially supported today through message search; dedicated pattern engine still needed |
| `topic_search` | `semantic_retrieval` | `first dollar`, `partnership discussions`, `people asking about onboarding` | Supported |
| `reply_queue` | `reply_triage` | `who do I need to reply to`, `who is waiting on me`, `who haven't I replied to` | Supported, but current implementation is still being tuned |
| `relationship` | `graph_crm` | `stale investors`, `top builders`, `who do I talk to most` | Foundation exists, end-user engine still needed |
| `summary` | `summarize` | `summarize my chats with Akhil`, `what did we decide`, `what happened in this group` | Foundation exists, end-user route still needed |

## Routing Principles

1. `exact_lookup` is about **literal presence**.
   - Best for wallet addresses, URLs, usernames, transaction hashes, contract addresses, and exact phrases.
   - Should eventually use a dedicated pattern engine with substring, regex, and fuzzy verification.

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

## Current Runtime Mapping

Until every engine is implemented, the runtime still falls back to the closest existing path:

| Preferred engine | Current runtime path |
| --- | --- |
| `message_lookup` | `message_search` |
| `semantic_retrieval` | `semantic_search` |
| `reply_triage` | `agentic_search` |
| `graph_crm` | `semantic_search` (temporary fallback) |
| `summarize` | `semantic_search` (temporary fallback) |

## Priority Follow-Up Work

1. Build a dedicated `PatternSearchEngine` for `exact_lookup`.
2. Replace one-chat-per-call reply triage with batched multi-chat AI triage.
3. Add graph-backed CRM execution for `relationship`.
4. Add retrieve-then-summarize execution for `summary`.
