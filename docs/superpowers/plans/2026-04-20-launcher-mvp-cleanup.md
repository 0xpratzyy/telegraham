# Launcher MVP Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refresh repo docs, remove obvious dead/duplicated code, and extract shared search-domain logic out of oversized view/coordinator files.

**Architecture:** Keep the launcher-first MVP intact while moving shared types and reply/follow-up logic into search-domain files. Favor behavior-preserving extraction over large rewrites.

**Tech Stack:** SwiftUI, AppKit, TDLibKit, GRDB, local eval/docs markdown

---

### Task 1: Refresh Source-Of-Truth Docs

**Files:**
- Modify: `docs/architecture.md`
- Modify: `docs/product-prd.md`
- Modify: `docs/task-tracker.md`

- [ ] Update the three top-level docs so they describe the current runtime structure, current MVP shape, and the current cleanup priorities.
- [ ] Remove stale branch-checkpoint style status that no longer reflects the working tree.

### Task 2: Extract Shared Search / Debug Models

**Files:**
- Create: `Sources/Search/Models/AgenticDebugModels.swift`
- Modify: `Sources/Search/Models/SearchModels.swift`
- Modify: `Sources/Views/SearchCoordinator.swift`
- Modify: `Sources/Views/SearchCoordinator+Agentic.swift`
- Create: `Sources/Views/Settings/QueryRoutingDebugSnapshot.swift`
- Modify: `Sources/Views/SettingsView.swift`

- [ ] Move shared agentic debug payloads out of `SearchCoordinator+Agentic.swift`.
- [ ] Move shared result enum ownership out of `SearchCoordinator.swift`.
- [ ] Move the routing debug snapshot type out of `SettingsView.swift`.

### Task 3: Move Reply / Follow-Up Logic Into Search Domain

**Files:**
- Create: `Sources/Search/ReplyQueue/ConversationReplyHeuristics.swift`
- Create: `Sources/Search/ReplyQueue/FollowUpPipelineAnalyzer.swift`
- Delete: `Sources/Views/ConversationReplyHeuristics.swift`
- Modify: `Sources/Search/ReplyQueueEngine.swift`
- Modify: `Sources/Views/SearchCoordinator+Agentic.swift`
- Modify: `Sources/Views/LauncherView.swift`

- [ ] Move reply heuristics out of `Sources/Views`.
- [ ] Add one shared reply-signal evaluation path and replace duplicated call-site logic.
- [ ] Extract launcher follow-up categorization into a dedicated analyzer/service file.

### Task 4: Remove Obvious Dead Or Redundant Pieces

**Files:**
- Modify: `Sources/Views/SearchCoordinator.swift`
- Delete: `default.profraw`

- [ ] Remove unused `SearchCoordinator.triggerSearch` parameters or dead helpers.
- [ ] Remove transient artifacts that do not belong in the repo root.

### Task 5: Verify

**Files:**
- Test: repo-wide build/tests as available

- [ ] Run at least one build/test verification pass after refactor.
- [ ] Record any remaining architecture debt in the final summary instead of silently ignoring it.
