# Pidgy Task Tracker

Last updated: 2026-05-09

This tracker is the living status view for the current launch scope: fast launcher search plus a lightweight dashboard for attention, tasks, topics, people context, and dashboard-native preferences.

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
- `done` dashboard has Dashboard, Reply queue, Tasks, Topics, and People pages
- `done` dashboard has native Preferences for Telegram credentials, AI providers, bot inclusion, indexing status, diagnostics, and reset
- `done` `AttentionStore` reuses follow-up pipeline state for dashboard attention views
- `done` `TaskIndexCoordinator` discovers dashboard topics and extracts chat-scoped tasks from local messages
- `done` dashboard topics, tasks, evidence, status, and per-chat sync state persist in SQLite
- `done` dashboard task status actions exist: done, snooze, ignore, open chat
- `done` dashboard AI usage is tracked as dedicated request kinds
- `done` dashboard parser/storage/filter basics are covered by unit tests
- `done` topic pages combine local semantic search, FTS/vector message hits, recent messages, reply queue items, and tasks
- `done` people pages use graph/contact signals with lazy-rendered relationship context

### Search Quality / Infra

- `done` exact lookup artifact verification and outgoing bias upgrades
- `done` grounded topic-search evaluation and promoted topic-search scoring improvements
- `done` grounded summary evaluation, including broader person-scoped recap coverage
- `done` reply-queue batching, progressive rendering, and compact deterministic digests
- `done` shared chat eligibility filtering is centralized instead of duplicated across paths
- `done` reconnect / foreground recent-sync recovery is in place
- `done` durable major-chat coverage backfill: every major chat carries at least 30 days of local history, with per-chat cursor + retry backoff persisted in `chat_coverage_state` so progress survives sleep / restart / version migration
- `done` `MajorChatCoverageCoordinator` sweeps the full major-chat pool each pass with priority for non-error chats so quick local-pass wins land before slow network deep-history fetches
- `done` rate limiter splits `getChatHistoryLocal` (cache reads) from `getChatHistory` (network) so a stuck server fetch can't block the local fast-lane
- `done` 5-minute network timeout per attempt + 6 batches per chat lets large-history chats with downtime gaps (verified end-to-end against Telegram exports for 22k-message DMs) actually complete

### Architecture Cleanup

- `done` shared agentic debug payloads moved out of `SearchCoordinator+Agentic.swift`
- `done` reply / ownership heuristics moved out of `Sources/Views` into the search domain
- `done` launcher follow-up categorization logic extracted into `FollowUpPipelineAnalyzer`
- `done` dashboard UI monolith split into root, home/reply, tasks, topics, people, detail, row, shared-theme, and topic-search files
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
- `done` move settings into dashboard-native Preferences so configuration, privacy, indexing, diagnostics, and reset share the dashboard visual system

### Codebase Readability

- `in_progress` keep breaking oversized files into smaller focused units
- `in_progress` reduce the amount of domain logic still living inside `LauncherView`
- `in_progress` split dashboard model/parser/directory logic now that view files are separated
- `in_progress` retire or shrink legacy `SettingsView` now that visible settings entry points use dashboard Preferences
- `in_progress` keep shrinking `SearchCoordinator` toward orchestration instead of engine-heavy logic
- `in_progress` consider extracting dashboard persistence helpers out of `DatabaseManager` once dashboard behavior stops moving

### Data Coverage

- `done` 30-day local message history is enforced across every major chat by `MajorChatCoverageCoordinator`
- `in_progress` increase deep-index coverage now that two-worker indexing is live
- `in_progress` verify local-first retrieval still behaves well on colder but recent chats

## Next

1. `next` run a launch dogfood pass over launcher search, reply queue, dashboard tasks, task status changes, restart, reset, and Telegram deep links
2. `next` tune dashboard task output prompts on real misses and add a small dashboard eval fixture set
3. `next` implement or explicitly scope stale/closed dashboard task reconciliation
4. `next` clarify dashboard refresh/cost UX and decide whether background extraction should be opt-in, manual-first, or always-on after auth
5. `next` polish dashboard placeholder affordances: global search is not fully wired and `Re-index` currently means dashboard refresh, not full deep indexing
6. `next` split `LauncherView` result rendering into focused subviews / files
7. `next` split or retire old `SettingsView` now that dashboard Preferences owns visible settings
8. `next` split `DashboardModels` into DTO/parser/filter/people-directory files
9. `next` carve semantic/topic ranking helpers out of `SearchCoordinator`
10. `next` dogfood summary + reply-queue changes in the live app and turn misses into grounded tests/evals
11. `next` add more reply-queue fixtures for group-vs-DM precision and degraded-mode visibility
12. `next` validate whether the broader safer group benchmark branch should replace the current reply-queue prompt winner

## Launch Readiness Checklist

- `next` clean build and full `PidgyTests` pass on the current branch
- `next` live dashboard QA with AI configured, including topic discovery and task extraction
- `next` live no-AI/degraded dashboard QA so empty states are honest
- `done` verify dashboard Preferences replaces old settings entry points cleanly
- `next` verify `Delete All Data` stops dashboard indexing before deleting the app-support directory
- `next` verify background dashboard extraction cannot silently surprise the user with cost
- `next` confirm app restart preserves task status and does not duplicate extracted tasks
- `next` document known non-launch scope in UI/docs: no send automation, no proactive reminders, no graph-backed CRM execution

## Beta Distribution — blocked on Apple Developer Program

These items unblock once Deeksha's Apple Developer Program enrollment finishes
(applied 2026-05-09, typically active within 24–48 hours). The Pidgy build is
already shipping ad-hoc-signed via `scripts/make_dmg.sh`; the items below
upgrade the chain to "no Gatekeeper warnings ever".

- `blocked` add Pratyush as Developer/Admin in Deeksha's App Store Connect → Access → Users so his Mac's Xcode can pick the team
- `blocked` swap `project.yml` from ad-hoc (`CODE_SIGN_IDENTITY: "-"`) to the Developer ID identity once it appears in `security find-identity`
- `blocked` one-time `xcrun notarytool store-credentials pidgy-beta` on the build machine using an app-specific password from appleid.apple.com
- `blocked` first notarized .dmg via `scripts/make_dmg.sh --sign "Developer ID Application: …" --notarize`; verify via `xcrun stapler validate` + `spctl -a -t open --context context:primary-signature -vvv`
- `blocked` wire Sparkle for in-app auto-updates (signs each release with EdDSA, hosts appcast.xml from the repo, lets Sparkle download + install on next launch). Notarized signing pairs cleanly with Sparkle so testers never see Gatekeeper after the first install.
- `blocked` extend `scripts/make_dmg.sh` (or a new `scripts/release.sh "v0.1.x" "notes"`) to: bump `MARKETING_VERSION`, sign the .dmg, regenerate appcast.xml entry, push to a GitHub release, commit the appcast update.
- `next` build in-app **Send feedback** widget (menu item + ⌘? hotkey) that POSTs to a Discord/Slack webhook with build SHA, OS version, and the last 200 OSLog entries. Doesn't depend on the developer cert — can ship before notarization lands.
- `next` document the tester install + bug-report flow in README once the notarized .dmg is the canonical artifact (currently README still describes the ad-hoc Privacy & Security override).
- `later` decide if Sentry (or similar) crash capture is worth the privacy disclosure for the cohort, after first ~5 manual reports come in.

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
