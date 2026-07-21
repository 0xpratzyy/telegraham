# Pidgy Task Tracker

Last updated: 2026-07-21

**Active work is tracked in GitHub issues now** —
<https://github.com/0xpratzyy/telegraham/issues>. This file only records the
shipped baseline so the issues have context.

## Shipped baseline (as of commit `b963b7a`)

- Durable SQLite message history as the local source of truth; recent sync,
  30-day major-chat coverage, and deep indexing as separate coordinators.
- **Context layer (#48)**: bi-temporal fact store extracted from messages;
  tasks and the reply queue are views over open loops (`i_owe` reply/action,
  `owes_me`); structural (never content-based) reply-close; rolling per-chat
  entity summaries; runtime kill-switch (Preferences → Memory engine —
  freezes views, no legacy fallback).
- **Ask Pidgy** answer chat in the launcher (auto-opens for person questions
  and reply-queue questions; grounded in facts + summaries, with
  `pidgy://chat` backlinks and follow-up history).
- Local-first search: exact lookup (`PatternSearchEngine`), fused FTS+vector
  topic search with optional rerank, deep recap (`SummaryEngine`).
- Dashboard: Home blended feed, Reply queue, Tasks, editorial Topics
  catch-me-up with click-to-explore, People (RelationGraph), dashboard-native
  Preferences.
- On-device photo OCR into message text; on-device embeddings.
- AI proxy (Cloudflare Worker, Gemini via Vertex) for the managed plan;
  per-stage request kinds + model routing; payments shipped dormant.
- July 2026 architecture cleanup: legacy per-surface AI pipelines deleted
  (~13.5k lines net), god files split, suite at 193 tests / 0 failures.

## Open work

| # | Issue |
|---|---|
| [#58](https://github.com/0xpratzyy/telegraham/issues/58) | CI: run the test suite on every push |
| [#59](https://github.com/0xpratzyy/telegraham/issues/59) | Fix 5 skipped SummaryEngine retrieval regressions |
| [#60](https://github.com/0xpratzyy/telegraham/issues/60) | Central AI scheduler |
| [#61](https://github.com/0xpratzyy/telegraham/issues/61) | Retire idle polling loops |
| [#62](https://github.com/0xpratzyy/telegraham/issues/62) | Gradual DI over `.shared` singletons |
| [#63](https://github.com/0xpratzyy/telegraham/issues/63) | Release preflight: assert bundled AI proxy URL |
| [#64](https://github.com/0xpratzyy/telegraham/issues/64) | Reply-queue graceful degraded mode |
| [#65](https://github.com/0xpratzyy/telegraham/issues/65) | Decide: auto-expiry for stale fact tasks |

Historical eval sheets, benchmark matrices, and model-swap results live in
[docs/archive/](archive/) — they are dated records of past experiments, not
current behavior.
