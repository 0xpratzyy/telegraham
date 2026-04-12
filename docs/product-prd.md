# Pidgy Product PRD

Last updated: 2026-04-11

## Product Thesis

Pidgy turns Telegram from raw chat history into usable relationship state.

The product is not trying to replace Telegram. It is trying to make Telegram operable for people whose work already lives there:

- BD and partnerships
- founder outreach
- community operations
- support-like follow-ups
- builder and investor relationship management

The long-term direction is an agentic personal CRM. The MVP is the thinnest useful surface on the way there: a fast launcher that helps the user find context, understand ownership, and act.

## Why This MVP Exists

The user problem is not just "search is bad."

The real problem is that important relationship state is buried inside hundreds of Telegram threads:

- where did I send that wallet, link, or contract?
- which chat actually needs my reply?
- what did we decide with this person?
- is this waiting on me or them?

The MVP exists to make those answers fast enough and trustworthy enough that a heavy CRM workflow is not required.

## Product Summary

Pidgy is a launcher-first, local-first Telegram copilot for hybrid BD and community operators.

The MVP promise is:

- find the right message or chat fast
- know whether a thread is on you
- prep the next reply with the right context

Pidgy is not a full CRM in MVP. It is the operational layer that sits on top of Telegram before a larger CRM layer exists.

## Primary User

### Hybrid BD / Community operator

This user:

- runs partnerships, outreach, follow-ups, and intros
- also manages groups, builders, support-like asks, and community threads
- lives inside Telegram all day
- loses track of open loops across DMs, groups, links, wallets, and stale threads

## Core Jobs To Be Done

1. Find the exact message or entity I’m looking for.
2. Find chats related to a topic, company, or project.
3. See which conversations are currently on me.
4. Prepare quickly before replying.
5. Stay inside one fast launcher instead of switching into a heavy dashboard.

## MVP Product Shape

Launcher is the primary surface.

MVP supports four query families:

1. `exact_lookup`
2. `topic_search`
3. `reply_queue`
4. `summary`

`relationship / graph_crm` queries are recognized by the router, but not shipped as a dedicated end-user engine in MVP.

## Core MVP Experiences

### 1. Exact Lookup

Example queries:

- `where I shared wallet address`
- `find message with contract address`
- `where did I send this URL`

Expected output:

- message-first results
- strongest literal/entity match near the top
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
- AI rerank only when it materially improves ordering

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

This is the first true CRM primitive in the product. It is the first place where Pidgy converts raw chat history into ownership state.

### 4. Summary / Reply Prep

Example queries:

- `summarize my chats with Akhil`
- `what did we decide with Maaz`
- `what happened in this group last week`

Expected output:

- one bounded summary card
- supporting chats/messages underneath
- retrieval-first synthesis, not a giant broad report

## Why Launcher-First

Launcher-first is a product choice, not a temporary UI limitation.

It keeps the product:

- fast
- lightweight
- query-driven
- close to Telegram behavior instead of replacing it

The launcher proves whether Pidgy can reliably answer operational questions before a larger CRM surface is added.

## How MVP Leads To Agentic CRM

The bridge is structured relationship state.

Today, the product is learning to derive from chats:

- latest actionable ask
- likely owner of the next step
- whether the thread is open, stale, or closed
- suggested next move

That same structured state can later power:

- `who should I follow up with`
- `who am I waiting on`
- `which warm leads went stale`
- `prep me for this meeting`
- pipeline stage / relationship health
- compiled memory for people, chats, and projects

So the direction is:

1. raw messages
2. launcher retrieval and judgment
3. structured chat / relationship state
4. agentic CRM workflows
5. compiled memory layer

This is one roadmap, not multiple product pivots.

## Explicitly Out Of MVP

Not in MVP now:

- dedicated CRM/relations dashboard
- proactive alerts / reminders
- auto-send or message sending
- full workflow automation
- polished graph-backed CRM execution engine
- compiled-memory compiler in the search hot path

These are not rejected forever. They are deferred until the launcher-first operational layer is trusted.

## Product Principles

1. Local-first by default.
2. Launcher-first before dashboard-first.
3. Use AI where it improves judgment, not where local retrieval is enough.
4. Prefer read-only and explicit actions over silent automation.
5. Different query types should use different engines.
6. Durable local history should not be thrown away by normal cache refresh behavior.
7. Search-time networking is an anti-goal; freshness should already be in local SQLite by the time the user searches.
8. Trust matters more than breadth for responsibility questions like reply queue.

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

## Success Criteria

Pidgy MVP is successful if a user can:

1. find an exact wallet / link / contract message they sent
2. find topic-related chats quickly
3. get a useful reply queue without excessive waiting
4. prepare for a reply using a quick summary
5. trust that the launcher is routing the query to the right family
6. trust that fresh local data is already available without search-time Telegram fetches

## Product Health Metrics

The most important MVP health signals are:

- reply queue trust: top rows feel mostly right
- reply queue latency: useful results appear quickly enough to use daily
- exact lookup hit quality: correct message is near the top
- freshness: new Telegram activity lands in local SQLite quickly
- local coverage: deep indexing keeps making more chats search-ready

## Current Known Gaps

- reply queue quality is improving but still needs more group precision tuning
- reconnect/network-recovery recent-sync coverage still needs strengthening
- summary is still mostly single-chat synthesis, not full cross-chat rollup
- relationship queries are recognized but intentionally unsupported in MVP runtime
- automated regression coverage exists for the core storage/routing/summary slice, but still needs more reply-queue fixtures

## Related Docs

- [Task Tracker](/Users/pratyushrungta/telegraham/docs/task-tracker.md)
- [Architecture](/Users/pratyushrungta/telegraham/docs/architecture.md)
- [Query Engine Matrix](/Users/pratyushrungta/telegraham/docs/query-engine-matrix.md)
