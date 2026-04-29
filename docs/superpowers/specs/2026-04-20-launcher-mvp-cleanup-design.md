# Launcher MVP Cleanup Design

## Goal

Bring the repo back in line with the launcher-first MVP by:

- updating architecture / product / tracker docs to match the working tree
- removing clearly dead or duplicated code
- moving shared search-domain logic out of view-heavy files
- making the largest files easier to reason about without rewriting product behavior

## Scope

In scope:

- search / launcher / settings architecture cleanup
- shared model extraction
- reply / follow-up duplication cleanup
- documentation refresh

Out of scope:

- changing the product surface
- removing graph foundation that is still wired into startup/debug flows
- rewriting search engines from scratch

## Design Decisions

### 1. Keep The MVP Shape

The launcher-first, local-first product shape remains the source of truth. Cleanup should reinforce that shape instead of introducing a new architecture.

### 2. Move Shared Domain Logic Out Of Views

Reply heuristics and follow-up categorization are search-domain concerns. They should not live under `Sources/Views`.

### 3. Prefer Extraction Over Rewrite

When a file is too large, first extract shared types and focused helpers. Do not destabilize active search quality work with a broad rewrite.

### 4. Remove Only Clearly Dead Or Duplicated Code

Safe removals include:

- dead artifacts
- duplicated parameters
- duplicate heuristics callers after a shared evaluator exists

Keep dormant-but-integrated systems such as graph foundation.

## File Direction

- `Sources/Search/Models/*` should hold cross-engine search/debug models.
- `Sources/Search/ReplyQueue/*` should hold reply / follow-up heuristics and related support logic.
- `Sources/Views/*` should primarily compose UI and delegate to search/services.
- docs should describe current structure, not past branch checkpoints.

## Intended Outcome

After this pass:

- fewer large view-owned logic blobs
- fewer duplicated reply-signal computations
- clearer ownership between launcher UI and search/follow-up domain logic
- docs that match the actual repo
