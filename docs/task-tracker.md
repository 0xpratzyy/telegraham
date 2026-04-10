# Pidgy Task Tracker

Last updated: 2026-04-09

This is the living delivery tracker for the current launcher-first MVP.

## Status Legend

- `done`: shipped in code
- `in_progress`: built but still being tuned or hardened
- `next`: highest-priority remaining work
- `later`: intentionally deferred

## Done

### Foundation

- `done` rate limiting improvements for Telegram reads
- `done` SQLite migration and local source of truth
- `done` made `messages` the durable local history table
- `done` moved hot-cache semantics to memory instead of SQLite trimming
- `done` FTS-first keyword search
- `done` graph schema + graph builder foundation
- `done` deep indexing scheduler foundation
- `done` local embeddings + vector store
- `done` DB hygiene bundle: sender index, embeddings cascade, explicit cleanup, throttled backfill

### Query routing

- `done` query family taxonomy
- `done` router/parser foundation
- `done` launcher routing snapshot for development/debug

### MVP engines

- `done` `PatternSearchEngine`
- `done` `SummaryEngine`
- `done` `ReplyQueueEngine`
- `done` semantic/topic search engine integrated into launcher

### Launcher UX

- `done` exact lookup results render message-first
- `done` topic search results render chat-first
- `done` summary can render a summary card
- `done` reply queue can render actionable rows
- `done` reply queue now shows confident rows progressively while scan continues
- `done` reply queue now sorts recent-first instead of confidence-first
- `done` reply queue now uses compact deterministic chat digests instead of raw full chat payloads
- `done` reply queue now uses dedicated `gpt-5.4-mini` model routing for OpenAI
- `done` reply queue AI batching now runs as 4 parallel x 12 batches over the capped candidate set

### Product docs

- `done` product PRD
- `done` task tracker
- `done` architecture doc
- `done` workflow note to always run a subagent audit before major MVP/search pushes
- `done` workflow note to update docs alongside every meaningful commit

## In Progress

### Reply queue quality

- `in_progress` improve precision for group reply detection
- `in_progress` keep latency under control as eligible chat counts grow
- `in_progress` tune batched triage prompt/provider behavior
- `in_progress` reduce over-compression in compact chat digests so actionable asks are not dropped
- `in_progress` loosen heuristic hard-rejects where they block AI from rescuing true group obligations
- `in_progress` verify local-only first pass does not miss cold but recent chats
- `in_progress` fix timing/debug accounting for parallel AI batches

### Exact lookup quality

- `in_progress` improve entity detection and outgoing bias quality
- `in_progress` reduce blunt generic message-search fallthrough behavior

### Summary quality

- `in_progress` improve bounded summaries for `what did we decide` style queries
- `in_progress` expand from single-chat to multi-chat synthesis where query intent needs it

## Next

1. `next` tighten reply-queue output quality, especially group-targeting precision
2. `next` improve exact lookup ranking for wallets, links, domains, and handles
3. `next` add explicit `Draft reply` action for summary/reply-prep states
4. `next` add minimal automated tests for routing, summary time windows, and durable-history preservation
5. `next` tighten reply-queue fallback visibility when provider triage fails

## Later

### Post-MVP

- `later` dedicated graph/CRM execution engine
- `later` stale investors / top builders / warm leads as real graph queries
- `later` dedicated CRM/relations view
- `later` proactive alerts / reminders
- `later` send path / workflow automation

## Current Branch Checkpoint

Current active WIP branch:

- `codex/durable-message-history`

Latest checkpoint pushed during this phase:

- commit `5a7e189`
- message `Make messages durable local history`

## Related Docs

- [Product PRD](/Users/pratyushrungta/telegraham/docs/product-prd.md)
- [Architecture](/Users/pratyushrungta/telegraham/docs/architecture.md)
