# Pidgy Product PRD

Last updated: 2026-04-29

## Product Thesis

Pidgy makes Telegram operational for people whose work already lives there.

The product is not trying to replace Telegram or force users into a full CRM. It is trying to answer the operational questions that Telegram alone handles badly:

- where did I send that exact thing?
- which chat is on me right now?
- what happened with this person or topic?
- what context do I need before replying?
- what should I handle first today?

## Product Summary

Pidgy is a local-first Telegram copilot for BD, partnerships, community, and operator workflows.

The current MVP promise is:

1. exact lookup for messages and artifacts
2. topic search across chats
3. reply queue / ownership triage
4. quick recap / reply prep summaries
5. a lightweight dashboard for active work, reply attention, topics, and people context
6. dashboard-native preferences for configuration, privacy, and diagnostics

## Primary User

Hybrid BD / community operators who:

- live in Telegram all day
- manage DMs and groups at the same time
- lose ownership state across dozens or hundreds of threads
- need speed and trust more than a heavyweight CRM workflow

## Core Jobs To Be Done

1. Find the exact message, link, wallet, handle, or contract I need.
2. Find the chats related to a topic, company, or project.
3. See which conversations likely need my reply.
4. Prep quickly before responding.
5. Start the day with a scannable view of active tasks and relationship attention.
6. Stay close to Telegram instead of adopting a heavyweight CRM workflow.

## Current MVP Surface

Launcher is the primary query surface. Dashboard is the secondary operating surface. Preferences should live inside the dashboard so setup, sync status, privacy, and diagnostics feel like part of the same operating cockpit instead of a separate app.

Supported product experiences:

### 1. Exact Lookup

Examples:

- `where I shared wallet address`
- `find message with contract address`
- `where did I send this URL`

Expected behavior:

- message-first ranking
- exact artifacts near the top
- strong outgoing bias for `I sent / shared / pasted`
- safe no-result behavior when the specific artifact is missing

### 2. Topic Search

Examples:

- `first dollar`
- `partnership discussions`
- `people asking about onboarding`

Expected behavior:

- chat-first results
- supporting snippets underneath
- local-first retrieval from FTS + vector signals
- rerank only when it meaningfully improves ordering

### 3. Reply Queue

Examples:

- `who do I need to reply to`
- `who is waiting on me`
- `which chats need my response`

Expected behavior:

- actionable queue of chats
- recent-first usefulness
- progressive rendering while AI triage continues
- better trust than generic semantic search for ownership questions

Reply queue is the first true CRM primitive in the product.

### 4. Summary / Reply Prep

Examples:

- `summarize my chats with Akhil`
- `what did we decide with Maaz`
- `what happened in this group last week`

Expected behavior:

- bounded, retrieval-first recap
- support messages underneath
- more trust than a free-form “summarize everything” chat answer

### 5. Dashboard

Dashboard answers: "what needs attention now?"

Current pages:

- Dashboard: merged feed of open tasks and reply attention
- Reply queue: scannable conversations where the user may owe a response
- Tasks: AI-extracted work items with topic, priority, evidence, and status actions
- Topics: workspace-like pages for companies, projects, communities, and operating themes
- People: top/stale contacts from relationship graph context with related work

Expected behavior:

- lightweight operating view, not a full CRM
- extracted tasks must cite Telegram message evidence
- user actions can mark tasks done, snoozed, or ignored
- manual task state should survive refreshes
- dashboard extraction should run from local indexed/recent data
- topics should prefer user-relevant workspaces such as companies/projects over generic categories
- topic pages should provide search, catch-up, open tasks, needs-reply, related chats, and highlighted people/group context
- people pages should open quickly, lazy-load heavier context, and summarize recent relationship context from local messages
- dashboard cost/freshness should be understandable before launch

### 6. Preferences

Preferences live inside the dashboard.

Expected behavior:

- open from the dashboard sidebar/account menu and from existing menu-bar/launcher settings actions
- keep a calm dark macOS-native layout consistent with the dashboard
- group settings into clear sections: account, Telegram connection, AI providers, indexing, data/privacy, diagnostics, and reset
- keep advanced routing/index/debug tools available but visually secondary
- make background AI extraction and indexing cost/freshness understandable in product language

## Product Principles

1. Local-first is the default.
2. Launcher-first for direct intent, dashboard for operating overview.
3. Different query families should use different engines.
4. Use AI for judgment, not for work local retrieval can already do.
5. Search-time networking is an anti-goal.
6. Reply / ownership questions must optimize for trust over breadth.
7. Freshness and deep indexing are background responsibilities, not query-time responsibilities.
8. Dashboard tasks need evidence and lifecycle behavior, not just nice wording.
9. Settings and diagnostics should feel like part of the dashboard product, not a separate utility bolted on later.

## What Is In Product But Not Primary

These exist in the codebase, but are not the core shipped promise:

- graph foundation and relationship scoring
- launcher follow-up cache / categorization support paths
- debug surfaces for routing, indexing, graph state, and usage
- dashboard topic taxonomy and task extraction internals
- dashboard Preferences / diagnostics internals

These are supporting systems, not the headline MVP experience.

## Explicitly Out Of Scope For This MVP

Not part of the current shipped promise:

- full CRM pipeline management
- proactive reminders / alerts
- message sending or auto-send
- workflow automation
- graph-backed end-user CRM query engine
- replacing Telegram as the main communication client
- team billing, referrals, templates, or workspace collaboration controls

## Success Criteria

Pidgy MVP is working if a user can reliably:

1. recover a specific artifact they sent
2. find relevant topic chats quickly
3. trust the top of the reply queue often enough to use it daily
4. get a useful, bounded recap before replying
5. trust that the launcher routes the query to the right family
6. open the dashboard and see evidence-backed tasks / attention items without obvious stale noise
7. configure Telegram, AI, indexing, privacy, and diagnostics without leaving the dashboard visual system

## Current Product Risks

The biggest product risks right now are:

- reply-queue precision in noisy groups
- summary quality for person-scoped and multi-chat recap prompts
- dashboard task extraction output quality: titles, suggested actions, priority, topic labels, and false-positive ownership need dogfooding
- stale dashboard tasks: closed-loop reconciliation exists for some reply-completed tasks, but broader stale/open-loop cleanup still needs hardening
- dashboard AI cost/freshness expectations because background extraction can run without an explicit query
- deep-index coverage across larger local histories
- legacy settings/debug code still needs cleanup now that visible entry points route into dashboard-native Preferences
- UI readability as launcher, settings, and dashboard model/storage files accumulate page-specific rendering

## Launch Scope

Launch-ready means Pidgy can be trusted as a read-only operating layer over Telegram.

Must have before a proper launch:

1. Tune dashboard task outputs on real dogfood data.
2. Add stale/closed task reconciliation so resolved asks do not remain open forever.
3. Make dashboard refresh/cost behavior obvious, especially for background AI extraction.
4. Harden dashboard-native Preferences and remove or retire the old settings/debug surface.
5. Run live QA for launcher search, reply queue, dashboard refresh, task status changes, preferences, reset, restart, and Telegram deep links.
6. Keep launch read-only: no send automation, no proactive reminders, no full CRM pipeline controls.

Nice to have before launch:

1. Split remaining large launcher/settings/model files enough that fixes are easy to review.
2. Add dashboard-specific eval fixtures for false positives, closed loops, duplicate task fingerprints, and topic drift.
3. Polish placeholder controls such as global dashboard search and re-index wording so the UI does not imply unsupported behavior.

## Current Product Direction

The roadmap is still one continuous line:

1. raw Telegram messages
2. reliable launcher retrieval and ownership judgment
3. dashboard-visible operating state
4. dashboard-native preferences and diagnostics
5. structured relationship state
6. agentic CRM workflows

The codebase should keep biasing toward trustworthy retrieval, evidence-backed task state, and a lightweight dashboard before becoming a broad CRM product.
