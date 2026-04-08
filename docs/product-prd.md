# Pidgy Product PRD

Last updated: 2026-04-08

## Product Summary

Pidgy is a launcher-first, local-first Telegram copilot for hybrid BD and community operators.

The MVP promise is:

- find the right chat or message fast
- know whether you need to follow up
- prep a reply with the right context

Pidgy is not trying to be a full CRM in MVP. It is a fast operational layer on top of Telegram.

## Primary Users

### Hybrid BD / Community operator

This user:

- runs partnerships, outreach, follow-ups, and intros
- also manages groups, builders, support-like asks, and community threads
- lives inside Telegram all day
- loses context across DMs, groups, links, wallet addresses, and open loops

## Core Jobs To Be Done

1. Find the exact message or entity I’m looking for.
2. Find chats related to a topic or company.
3. See who is waiting on me.
4. Summarize the context before I reply.
5. Stay fast inside one launcher without opening a full CRM tool.

## MVP Product Shape

Launcher is the primary surface.

MVP supports four query families:

1. `exact_lookup`
2. `topic_search`
3. `reply_queue`
4. `summary`

`relationship / graph_crm` queries are recognized by the router, but not implemented as a dedicated end-user engine in MVP.

## Core MVP Experiences

### 1. Exact Lookup

Example queries:

- `where I shared wallet address`
- `find message with contract address`
- `where did I send this URL`

Expected output:

- message-first results
- strongest match near the top
- outgoing messages boosted when the query implies `I shared / I sent / I pasted`
- snippets and timestamps visible immediately

### 2. Topic Search

Example queries:

- `first dollar`
- `partnership discussions`
- `people asking about onboarding`

Expected output:

- chat-first results
- matched snippets underneath
- local-first performance using FTS + vectors
- optional AI rerank only when it materially improves ordering

### 3. Reply Queue

Example queries:

- `who do I need to reply to`
- `who is waiting on me`
- `which chats need my response`

Expected output:

- actionable chat queue
- clear next-step suggestion
- recent-first ordering
- progressive rendering: show confident chats early while the rest is still being triaged

### 4. Summary / Reply Prep

Example queries:

- `summarize my chats with Akhil`
- `what did we decide with Maaz`
- `what happened in this group last week`

Expected output:

- one bounded summary card
- supporting chats/messages underneath
- retrieval-first summary, not a giant broad report

## Explicitly Out Of MVP

- dedicated CRM/relations dashboard
- proactive alerts / reminders
- auto-send or message sending
- full workflow automation
- graph-backed relationship queries as a polished end-user feature

## Product Principles

1. Local-first by default.
2. Launcher-first before dashboard-first.
3. Use AI where it improves judgment, not where local retrieval is enough.
4. Prefer read-only and explicit actions over silent automation.
5. Different query types should use different engines.
6. Durable local history should not be thrown away by normal cache refresh behavior.

## Query Family Rules

### `exact_lookup`

Use for literal or entity presence:

- wallet addresses
- URLs
- domains
- handles
- exact phrases

### `topic_search`

Use for concept/topic discovery:

- companies
- partnerships
- onboarding
- integrations

### `reply_queue`

Use for responsibility / open-loop questions:

- on me
- waiting on me
- need response

### `summary`

Use for prep and synthesis after retrieval.

### `relationship`

Recognize it now, defer full execution to post-MVP.

## MVP Success Criteria

Pidgy MVP is successful if a user can:

1. find an exact wallet / link / contract message they sent
2. find topic-related chats quickly
3. get a useful reply queue without excessive waiting
4. prepare for a reply using a quick summary
5. trust that the launcher is routing the query to the right family during development

## Current Known Gaps

- reply queue quality is improving but still needs tuning
- summary is still mostly single-chat synthesis, not full cross-chat rollup
- relationship queries are recognized but intentionally unsupported in MVP runtime
- automated test coverage is still thin for launcher/search/storage regressions

## Related Docs

- [Task Tracker](/Users/pratyushrungta/telegraham/docs/task-tracker.md)
- [Architecture](/Users/pratyushrungta/telegraham/docs/architecture.md)
- [Query Engine Matrix](/Users/pratyushrungta/telegraham/docs/query-engine-matrix.md)
