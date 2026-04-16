# Pidgy Task Tracker

Last updated: 2026-04-14

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
- `done` added `recent_sync_state` as a freshness store separate from deep-index `sync_state`
- `done` added `RecentSyncCoordinator` for startup/foreground/prioritized recent sync
- `done` FTS-first keyword search
- `done` graph schema + graph builder foundation
- `done` deep indexing scheduler foundation
- `done` local embeddings + vector store
- `done` DB hygiene bundle: sender index, embeddings cascade, explicit cleanup, throttled backfill
- `done` moved embedding backfill off the hot indexing loop and into idle-time work
- `done` deep indexing now runs with up to 2 concurrent chat workers
- `done` live Debug observability for recent sync and deep indexing session progress
- `done` added eval-first routing coverage for many product prompt phrasings, not just one canonical query per feature
- `done` added a main-thread GPT-5.4 product prompt oracle with 50 user inputs across all routing families plus a comparator script
- `done` added a grounded exact-lookup final-answer oracle and scorer so exact lookup can be judged on top-1/top-3/no-result behavior instead of routing only
- `done` expanded exact lookup from `oracle_v1` to a broader grounded `oracle_v2` with `37` cases across URLs, repos, X links, Meet links, handles, emails, addresses, and no-result traps
- `done` added grounded summary final-answer oracles and a scorer so summary can be judged on focus chat, supporting evidence, fact coverage, and no-result behavior instead of routing only
- `done` expanded summary from `oracle_v1` to a broader grounded `oracle_v2` with `18` cases across follow-ups, decisions, product gaps, tooling options, team briefs, strategy notes, QA feedback, and strict no-result traps
- `done` tuned the script-only summary winner `focus_chat_v4` to `100%` focus / `100%` support / `100%` fact coverage / `100%` strict pass on the broader grounded `summary_oracle_v2`
- `done` added a grounded topic-search final-answer oracle and scorer so topic search can be judged on chat ranking, snippet quality, and no-result behavior instead of routing only
- `done` tuned the script-only topic-search winner `topic_guarded_v3` to `100%` top-1 / `100%` top-3 / `100%` snippet / `100%` strict pass / `100%` no-result coverage on the grounded `topic_search_oracle_v1`
- `done` expanded topic search to a more realistic mined-from-local-data `topic_search_oracle_v2` and validated that `topic_guarded_v3` still clears it at `100%` across hit and no-result metrics
- `done` promoted the script-side routing winner into `QueryInterpreter` so broader reply, summary, relationship, and exact-lookup phrasings now match the GPT-5.4 routing oracle more closely
- `done` promoted the guarded exact-lookup winner into `PatternSearchEngine`, including stronger artifact verification for emails, Meet codes, platform hints, recipient-scoped artifact lookups, and no-result safety
- `done` promoted the `focus_chat_v4` summary winner ideas into `SummaryEngine`, including tighter focus gating, better anchor/support selection, and explicit rejection of fake person-topic overlap
- `done` fixed summary parsing so generic recap phrasing like `key takeaways` acts as a summary cue instead of a fake topic constraint for person-scoped recap queries
- `done` promoted the guarded topic-search winner into `SearchCoordinator`, including clue-aware semantic scoring, phrase/anchor coverage guards, and title-only suppression for weak topical matches
- `done` added product-side regression tests covering the promoted routing, exact lookup, and summary behaviors; `xcodebuild test -scheme Pidgy -destination 'platform=macOS'` now passes
- `done` added product-side semantic/topic regressions covering one realistic mined topical hit and one split-evidence no-result trap; `xcodebuild test -scheme Pidgy -destination 'platform=macOS'` now passes with `13` tests

### Query routing

- `done` query family taxonomy
- `done` router/parser foundation
- `done` launcher routing snapshot for development/debug

### MVP engines

- `done` `PatternSearchEngine`
- `done` `SummaryEngine`
- `done` `ReplyQueueEngine`
- `done` semantic/topic search engine integrated into launcher
- `done` semantic/topic search, exact lookup, and summary now stay local-only at query time

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
- `done` reply queue timing now measures parallel AI waves honestly
- `done` reply queue candidate snapshots are now debug-gated instead of always being written

### Product docs

- `done` product PRD
- `done` task tracker
- `done` architecture doc
- `done` workflow note to always run a subagent audit before major MVP/search pushes
- `done` workflow note to update docs alongside every meaningful commit
- `done` eval-first workflow doc so search/reply changes go through scripts/tests before live product promotion
- `done` bulk thesis eval runner covering unit-test gate, exact-lookup probe, topic-search probe, and reply-queue harness
- `done` AI settings save path now preserves an existing saved API key instead of overwriting it with blank during save/test flows
- `done` AIService persistence now refuses to overwrite a saved non-empty API key with blank for non-`none` providers
- `done` reply-queue benchmark scripts now auto-discover the provider-scoped OpenAI credential file and can complete live `gpt-5.4-mini` runs without manual key-path overrides
- `done` isolated unit tests onto a temp AI credential store so `xcodebuild test` no longer mutates live `Pidgy` provider settings in `~/Library/Application Support/Pidgy/credentials`
- `done` main-list chat discovery now keeps paging in the background after startup so deep indexing can continue beyond the first loaded chat batch, and Debug wording now calls out loaded main-list coverage explicitly

### Test floor

- `done` added `PidgyTests` unit test target
- `done` durable history preservation test
- `done` recent-sync readiness preservation test
- `done` query routing smoke test
- `done` summary time-window regression test
- `done` offline reply-queue gold benchmark harness with latency/cost/quality leaderboard
- `done` added private-recall reply-queue harness variants to improve DM recall without reopening noisy group false positives
- `done` exact-lookup local evidence probe script for validating exact-match availability before changing product behavior
- `done` topic-search local FTS probe script for validating local semantic/topic evidence before product tuning
- `done` added a canonical reply-queue variant matrix doc covering prompt families, digest fields, benchmark comparisons, and the current shipping recommendation
- `done` added a stricter Apr 12 group-focused reply-queue oracle so group-targeting precision can be measured on fresher real candidate snapshots before app-path changes
- `done` added an older group false-positive trap oracle plus new `digest_v6` reply-queue variants to benchmark explanation-style technical groups, cc-style mentions, and earlier requests-for-input before changing app behavior
- `done` added benchmark-only `worth_checking` support so reply-queue evaluation can distinguish true reply-now items from stale-but-real open loops like `Banko`
- `done` taught the reply-queue benchmark harness to treat closure phrases like `Already added` as real ownership handoffs, which cleaned up stale group false positives like `Bhavyam <> First Dollar` without touching the app path
- `done` added an exact-lookup benchmark sheet with grounded message-level expectations and current script-side leaderboard
- `done` exact-lookup script benchmark now has guarded winners at `100%` top-1 / `100%` top-3 / `100%` no-result coverage on the broader grounded `v2` oracle

## In Progress

### Freshness and indexing

- `in_progress` add stronger reconnect/network-recovery triggers for recent sync
- `in_progress` increase deep-index coverage now that 2-worker indexing is live

### Reply queue quality

- `in_progress` improve precision for group reply detection
- `in_progress` keep latency under control as eligible chat counts grow
- `in_progress` tune batched triage prompt/provider behavior
- `in_progress` reduce over-compression in compact chat digests so actionable asks are not dropped
- `in_progress` loosen heuristic hard-rejects where they block AI from rescuing true group obligations
- `in_progress` verify local-only first pass does not miss cold but recent chats
- `in_progress` tighten group-targeting precision so AI Weekends/Banko-style false positives fall out more reliably
- `in_progress` validate whether the safer broad benchmark branch `field_aware_groups_v3_private_recall_v2 + digest_v6` should replace the current script-side `digest_v5` winner after more real usage
- `in_progress` keep the sharper `field_aware_groups_v4_contextual_recovery_v1 + digest_v6` branch as a fresh-group research path until it stops reopening First-Dollar-style maybes
- `in_progress` keep tightening the new `worth_checking` surfaced bucket so stale open loops like `Banko` surface without dragging in the remaining accountability-style group noise

### Exact lookup quality

- `in_progress` improve entity detection and outgoing bias quality
- `in_progress` reduce blunt generic message-search fallthrough behavior
- `in_progress` improve exact-result ranking for phrase-specific link/doc queries like case studies, radar winners, and Product Hunt references
- `in_progress` keep expanding the exact-lookup oracle beyond `v2` as real user queries reveal new exact-retrieval shapes
- `done` exact URL queries now require the specific URL instead of letting nested domain matches leak in
- `done` broad `where I shared / sent` exact-lookup queries now apply stronger outgoing bias for entity-bearing messages
- `done` person-scoped artifact lookups like `wallet I sent to Rahul` now require both artifact evidence and recipient context instead of ranking generic Rahul mentions
- `done` artifact-transfer phrasing like `wallet I sent to Rahul` now routes to exact lookup instead of semantic/topic search

### Summary quality

- `in_progress` improve bounded summaries for `what did we decide` style queries
- `in_progress` expand from single-chat to multi-chat synthesis where query intent needs it
- `in_progress` keep expanding the summary oracle whenever real dogfooding exposes a new recap shape or summary failure mode

## Next

1. `next` tighten reply-queue output quality, especially group-targeting precision
2. `next` strengthen recent sync coverage for reconnect/network recovery so launcher stays local-first even after idle gaps
3. `next` decide whether to promote the script-side topic-search winner into product now or expand the topic oracle again after more dogfooding
4. `next` dogfood the promoted routing/exact/summary winners in the live app and turn misses into new grounded oracle cases
5. `next` add explicit `Draft reply` action for summary/reply-prep states
6. `next` add reply-queue fixtures for group-vs-DM precision and degraded-mode visibility
7. `next` replace production AI secret storage with real macOS Keychain usage while keeping injected temp storage for tests and a deliberate debug-build story that avoids silently mutating live user settings

## Later

### Post-MVP

- `later` dedicated graph/CRM execution engine
- `later` stale investors / top builders / warm leads as real graph queries
- `later` dedicated CRM/relations view
- `later` proactive alerts / reminders
- `later` send path / workflow automation
- `later` add an explicit “local coverage incomplete” state for exact lookup so partially indexed chats do not look identical to true no-result cases
- `later` relax summary joint-anchor gating so valid split-evidence conversations can still summarize when person and topic signals land in adjacent messages
- `later` evaluate whether AI settings should default to session-only after the Keychain migration lands, or stay persisted with an explicit user-facing toggle

## Current Branch Checkpoint

Current active WIP branch:

- `codex/durable-message-history`
- `codex/reply-queue-gpt54mini-parallel`

Latest checkpoint pushed during the prior reply-queue phase:

- commit `937d4e8`
- message `Speed up reply queue with parallel gpt-5.4-mini triage`

Current local checkpoint not yet pushed in this phase:

- freshness/deep-index split
- recent sync coordinator
- local-only search-time cleanup
- new regression tests
- live Debug observability for recent sync + deep indexing

## Related Docs

- [Product PRD](/Users/pratyushrungta/telegraham/docs/product-prd.md)
- [Architecture](/Users/pratyushrungta/telegraham/docs/architecture.md)
- [Reply Queue Harness](/Users/pratyushrungta/telegraham/docs/reply-queue-harness.md)
- [Eval-First Workflow](/Users/pratyushrungta/telegraham/docs/eval-first-workflow.md)
- [Thesis Bulk Eval](/Users/pratyushrungta/telegraham/docs/thesis-bulk-eval.md)
- [Product Prompt Benchmark Sheet](/Users/pratyushrungta/telegraham/docs/product-prompt-benchmark-sheet.md)
- [Exact Lookup Benchmark Sheet](/Users/pratyushrungta/telegraham/docs/exact-lookup-benchmark-sheet.md)
- [Summary Benchmark Sheet](/Users/pratyushrungta/telegraham/docs/summary-benchmark-sheet.md)
- [Topic Search Benchmark Sheet](/Users/pratyushrungta/telegraham/docs/topic-search-benchmark-sheet.md)
