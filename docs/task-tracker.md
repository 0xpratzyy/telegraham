# Pidgy Task Tracker

Last updated: 2026-04-27

This tracker is the living status view for the current launch scope: fast launcher search plus a lightweight dashboard for attention, tasks, and people context.

## Status Legend

- `done`: shipped in code
- `in_progress`: active work or recently landed but still being hardened
- `next`: highest-value follow-up work
- `later`: intentionally deferred

## Done

### Product + Search Foundation

- `done` durable SQLite message history is the local source of truth
- `done` recent sync and deep indexing are split into separate responsibilities
- `done` launcher search stays local-first at query time
- `done` exact lookup, topic search, reply queue, and summary are distinct query families
- `done` reply queue uses a dedicated engine instead of generic semantic search
- `done` summary uses retrieval-first synthesis instead of broad free-form summarization
- `done` OpenAI / Claude settings persist through Keychain-backed storage

### Dashboard Foundation

- `done` dashboard window is reachable from menu bar and launcher
- `done` dashboard has Dashboard, Reply queue, Tasks, and People pages
- `done` `AttentionStore` reuses follow-up pipeline state for dashboard attention views
- `done` `TaskIndexCoordinator` discovers dashboard topics and extracts chat-scoped tasks from local messages
- `done` dashboard topics, tasks, evidence, status, and per-chat sync state persist in SQLite
- `done` dashboard task status actions exist: done, snooze, ignore, open chat
- `done` dashboard AI usage is tracked as dedicated request kinds
- `done` dashboard parser/storage/filter basics are covered by unit tests

### Search Quality / Infra

- `done` exact lookup artifact verification and outgoing bias upgrades
- `done` grounded topic-search evaluation and promoted topic-search scoring improvements
- `done` grounded summary evaluation, including broader person-scoped recap coverage
- `done` reply-queue batching, progressive rendering, and compact deterministic digests
- `done` shared chat eligibility filtering is centralized instead of duplicated across paths
- `done` reconnect / foreground recent-sync recovery is in place

### Architecture Cleanup

- `done` shared agentic debug payloads moved out of `SearchCoordinator+Agentic.swift`
- `done` reply / ownership heuristics moved out of `Sources/Views` into the search domain
- `done` launcher follow-up categorization logic extracted into `FollowUpPipelineAnalyzer`
- `done` dead `default.profraw` artifact removed from tracked source; any regenerated local coverage artifact should stay untracked
- `done` stale top-level `QueryRoutingDebugSnapshot` type moved out of `SettingsView`
- `done` dead `visibleChats` parameter removed from `SearchCoordinator.triggerSearch`
- `done` docs refreshed to reflect current repo reality instead of older branch checkpoints

## In Progress

### Search Quality

- `in_progress` improve reply-queue precision for noisy groups
- `in_progress` keep reply-queue latency under control as candidate counts grow
- `in_progress` harden `worth_checking` handling so stale-but-real loops survive without reopening noise
- `in_progress` improve summary quality for person-scoped and multi-chat recap queries
- `in_progress` continue expanding grounded summary oracle coverage where dogfooding exposes misses

### Dashboard Launch Hardening

- `in_progress` tune task extraction outputs: title, summary, suggested action, priority, topic label, and confidence
- `in_progress` define stale/closed task reconciliation so resolved asks do not remain open forever
- `in_progress` make dashboard refresh behavior and AI cost expectations explicit
- `in_progress` dogfood task extraction on real Telegram histories and convert misses into tests/evals
- `in_progress` verify dashboard task refresh after prompt/output changes, because current per-chat sync state scans only newer message IDs

### Codebase Readability

- `in_progress` keep breaking oversized files into smaller focused units
- `in_progress` reduce the amount of domain logic still living inside `LauncherView`
- `in_progress` split `DashboardView` page/rendering/theme logic after the product shape stabilizes
- `in_progress` reduce the amount of debug / formatting logic still living inside `SettingsView`
- `in_progress` keep shrinking `SearchCoordinator` toward orchestration instead of engine-heavy logic
- `in_progress` consider extracting dashboard persistence helpers out of `DatabaseManager` once dashboard behavior stops moving

### Data Coverage

- `in_progress` increase deep-index coverage now that two-worker indexing is live
- `in_progress` verify local-first retrieval still behaves well on colder but recent chats

## Next

1. `next` run a launch dogfood pass over launcher search, reply queue, dashboard tasks, task status changes, restart, reset, and Telegram deep links
2. `next` tune dashboard task output prompts on real misses and add a small dashboard eval fixture set
3. `next` implement or explicitly scope stale/closed dashboard task reconciliation
4. `next` clarify dashboard refresh/cost UX and decide whether background extraction should be opt-in, manual-first, or always-on after auth
5. `next` polish dashboard placeholder affordances: `Search everywhere` is not wired and `Re-index` currently means dashboard refresh, not full deep indexing
6. `next` split `DashboardView` into page/detail/row/theme files enough to keep launch fixes reviewable
7. `next` split `LauncherView` result rendering into focused subviews / files
8. `next` split `SettingsView` tabs and debug helpers into dedicated units
9. `next` carve semantic/topic ranking helpers out of `SearchCoordinator`
10. `next` dogfood summary + reply-queue changes in the live app and turn misses into grounded tests/evals
11. `next` add more reply-queue fixtures for group-vs-DM precision and degraded-mode visibility
12. `next` validate whether the broader safer group benchmark branch should replace the current reply-queue prompt winner

## Launch Readiness Checklist

- `next` clean build and full `PidgyTests` pass on the current branch
- `next` live dashboard QA with AI configured, including topic discovery and task extraction
- `next` live no-AI/degraded dashboard QA so empty states are honest
- `next` verify `Delete All Data` stops dashboard indexing before deleting the app-support directory
- `next` verify background dashboard extraction cannot silently surprise the user with cost
- `next` confirm app restart preserves task status and does not duplicate extracted tasks
- `next` document known non-launch scope in UI/docs: no send automation, no proactive reminders, no graph-backed CRM execution

## Later

- `later` full CRM pipeline management
- `later` graph-backed end-user CRM execution
- `later` proactive alerts / reminders
- `later` send path / workflow automation
- `later` explicit “local coverage incomplete” UX for partially indexed exact lookup
- `later` deeper compiled-memory / relationship-state workflows on top of the launcher foundation

## Reference Docs

- [Architecture](/Users/pratyushrungta/telegraham/docs/architecture.md)
- [Product PRD](/Users/pratyushrungta/telegraham/docs/product-prd.md)
- [Reply Queue Harness](/Users/pratyushrungta/telegraham/docs/reply-queue-harness.md)
- [Summary Benchmark Sheet](/Users/pratyushrungta/telegraham/docs/summary-benchmark-sheet.md)
- [Topic Search Benchmark Sheet](/Users/pratyushrungta/telegraham/docs/topic-search-benchmark-sheet.md)
- [Exact Lookup Benchmark Sheet](/Users/pratyushrungta/telegraham/docs/exact-lookup-benchmark-sheet.md)
