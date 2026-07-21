# Pidgy Runtime QA via Computer Use

Date: 2026-04-20

Build used:
- Debug build from `Pidgy.xcodeproj`
- App path: `/Users/pratyushrungta/Library/Developer/Xcode/DerivedData/Pidgy-glaugonucssdxlerwjsjzvyatqah/Build/Products/Debug/Pidgy.app`

Test method:
- PRD-derived manual walkthrough
- Runtime launch + UI interaction through Computer Use
- Supplemental shell verification with `xcodebuild`, process checks, and local logs

## PRD-Derived Use Cases

Core launcher flows taken from `docs/product-prd.md`:

1. Exact lookup
   - Find a specific artifact, link, or message
   - Expect message-first ranking and safe empty states
2. Topic search
   - Find chats related to a company, project, or topic
   - Expect chat-first grouped results
3. Reply queue / ownership triage
   - Ask who needs a reply
   - Expect actionable queue, scope filters, and recent-first usefulness
4. Summary / reply prep
   - Ask for bounded recap on a person or thread
   - Expect summary card plus supporting context or a clear empty state
5. Launcher shell
   - Open app, switch All / DMs / Groups, and use queue state chips
6. Settings shell
   - Inspect auth/account/data settings without performing destructive actions

## What Worked

- App launched successfully from the fresh local Debug build.
- Default launcher state rendered immediately with reply queue items and visible scope chips.
- Top-level scope filters worked:
  - `All`
  - `DMs`
  - `Groups`
- Queue state chips worked within scoped lists:
  - `All`
  - `On Me`
  - `On Them`
  - `Quiet`
- Exact lookup worked for a real artifact-like query:
  - Query: `TradingView`
  - Result: 2 local chat matches
  - Observed UI completion time: about 7.5s
- Topic search worked for a broad project query:
  - Query: `first dollar`
  - Result: 13 chat results in `All`
  - `Groups` scope meaningfully changed the result list
  - Observed UI completion time: about 6.4s
- Reply queue query worked in group scope:
  - Query: `who do i need to reply to`
  - Result: confident group reply candidates with hot/warm labeling and suggested next actions
  - Observed UI completion time: about 7.4s
- Reply queue query worked in all scope:
  - Query: `who is waiting on me`
  - Result: ranked agentic queue with scores and suggested next actions
  - Observed UI completion time: about 17s
- Summary flow worked for a person-scoped decision query:
  - Query: `what did we decide with Rahul`
  - Result: summary card rendered with one supporting chat result
  - Observed UI completion time: about 2.5s
- Summary empty state worked:
  - Query: `summarize my chats with Akhil`
  - Result: `No summary context found`
  - Observed UI completion time: about 1.4s
- Exact search empty state worked:
  - Query: `zzqv unlikely artifact 993843`
  - Result: `No relevant chats found`
  - Observed UI completion time: about 5.2s
- Result activation works end-to-end:
  - Double-clicking the top `TradingView` result opened Telegram
  - Telegram focused the matching chat and showed the matching message in view

## What Did Not Work Well

- Local-first search feels slow in practice.
  - Exact and topic queries took roughly 6-8 seconds.
  - All-scope reply queue took roughly 17 seconds.
- Reply queue progress feels unstable.
  - The all-scope query appeared stuck at an intermediate scan count before eventually finishing.
  - This makes the flow feel partially hung even when it eventually resolves.
- Result handoff is fragile from an automation/integration perspective.
  - Computer Use reported Apple event error `-10005` during the double-click handoff.
  - End-user outcome still succeeded because Telegram opened to the right chat, but the handoff path is not cleanly automatable.
- Settings surface appears narrower than the rest of the codebase suggests.
  - In this pass, Settings only exposed Telegram credentials, account status, logout, and delete-local-data controls.
  - No AI/provider or search/debug settings were surfaced in the main settings window during runtime inspection.

## Untested On Purpose

These were visible but intentionally not executed because they are destructive or modify account state:

- `Save Credentials`
- `Log Out`
- `Delete All Local Data`

## Runtime Notes

- Supplemental logs showed outbound HTTPS activity during the session.
- Inference: at least some runtime paths are not behaving as purely local-only flows, even when the UI is framed as local search / ranking.
- A Core Animation render timeout was also observed once during the result activation sequence.

## Immediate Product Read

- Core launcher promise is real: search, reply queue, summary, filtering, and Telegram handoff are all present and usable.
- Biggest runtime weakness right now is speed and smoothness, not total feature absence.
- The most important follow-up is reducing query latency and making progress transitions feel trustworthy, especially for reply queue queries.
