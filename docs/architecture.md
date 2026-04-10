# Pidgy Architecture

Last updated: 2026-04-09

This is a living architecture doc for the launcher-first MVP.

## System Overview

Pidgy is a local-first macOS app built around three layers:

1. local data platform
2. query routing + search engines
3. launcher presentation

At a high level:

```mermaid
flowchart TD
    A["Telegram / TDLib"] --> B["Local storage layer"]
    B --> C["Query parser + router"]
    C --> D["PatternSearchEngine"]
    C --> E["Semantic retrieval engine"]
    C --> F["ReplyQueueEngine"]
    C --> G["SummaryEngine"]
    D --> H["Launcher UI"]
    E --> H
    F --> H
    G --> H
```

## 1. Local Data Platform

### Storage

Primary source of truth is SQLite via:

- [DatabaseManager.swift](/Users/pratyushrungta/telegraham/Sources/Storage/DatabaseManager.swift)
- [Migrations.swift](/Users/pratyushrungta/telegraham/Sources/Storage/Migrations.swift)

Key local stores:

- `messages`
- `sync_state`
- FTS tables
- `embeddings`
- graph tables (`nodes`, `edges`)

Current storage semantics:

- `messages` is the durable local history table
- recent hot-cache behavior lives in memory inside [MessageCacheService.swift](/Users/pratyushrungta/telegraham/Sources/Telegram/MessageCacheService.swift)
- recent disk fallback comes from `SELECT ... FROM messages ORDER BY date DESC LIMIT N`
- `sync_state` is owned by deep indexing, not by normal cache refreshes

At a high level:

```mermaid
flowchart TD
    A["TDLib live updates"] --> B["MessageCacheService memory cache (latest window)"]
    A --> C["messages table (durable upserts)"]
    D["IndexScheduler deep history"] --> C
    D --> E["sync_state"]
    C --> F["PatternSearchEngine"]
    C --> G["Semantic retrieval"]
    C --> H["SummaryEngine"]
    C --> I["ReplyQueueEngine"]
    C --> J["Recent fallback reads"]
```

### Indexing

Background indexing builds local retrieval quality over time:

- [IndexScheduler.swift](/Users/pratyushrungta/telegraham/Sources/Indexing/IndexScheduler.swift)
- [EmbeddingService.swift](/Users/pratyushrungta/telegraham/Sources/Indexing/EmbeddingService.swift)
- [VectorStore.swift](/Users/pratyushrungta/telegraham/Sources/Storage/VectorStore.swift)

The current safe default is:

- prioritize DMs and smaller groups
- skip channels by default for deep indexing

### Graph foundation

Relationship graph foundation exists in:

- [RelationGraph.swift](/Users/pratyushrungta/telegraham/Sources/Graph/RelationGraph.swift)
- [GraphBuilder.swift](/Users/pratyushrungta/telegraham/Sources/Graph/GraphBuilder.swift)

This is not yet the main MVP execution path for end-user CRM queries.

## 2. Query Routing Layer

The parser/router is the source of truth for query family selection.

Main files:

- [AIModels.swift](/Users/pratyushrungta/telegraham/Sources/AI/Models/AIModels.swift)
- [QueryInterpreter.swift](/Users/pratyushrungta/telegraham/Sources/AI/QueryInterpreter.swift)
- [QueryRouter.swift](/Users/pratyushrungta/telegraham/Sources/AI/QueryRouter.swift)

Current families:

- `exact_lookup`
- `topic_search`
- `reply_queue`
- `relationship`
- `summary`

Current engines:

- `message_lookup`
- `semantic_retrieval`
- `reply_triage`
- `graph_crm`
- `summarize`

## 3. Search Engines

### PatternSearchEngine

File:

- [PatternSearchEngine.swift](/Users/pratyushrungta/telegraham/Sources/Search/PatternSearchEngine.swift)

Purpose:

- exact/pattern/entity lookup

Current behavior:

- message-first results
- cheap local retrieval first
- regex/entity verification second
- outgoing bias when query implies `I shared / I sent / I pasted`

Current supported entity classes:

- exact phrases
- EVM-like addresses
- long address-like strings
- URLs
- domains
- `@handles`

### Semantic retrieval engine

Main orchestration:

- [SearchCoordinator.swift](/Users/pratyushrungta/telegraham/Sources/Views/SearchCoordinator.swift)

Supporting local retrieval:

- [TelegramService.swift](/Users/pratyushrungta/telegraham/Sources/Telegram/TelegramService.swift)
- [VectorStore.swift](/Users/pratyushrungta/telegraham/Sources/Storage/VectorStore.swift)

Purpose:

- concept/topic search

Current behavior:

- FTS + vector merge
- title evidence
- Telegram fallback for not-yet-indexed chats
- optional rerank

### ReplyQueueEngine

File:

- [ReplyQueueEngine.swift](/Users/pratyushrungta/telegraham/Sources/Search/ReplyQueueEngine.swift)

Purpose:

- identify chats where the user likely owes a response

Current behavior:

- coarse local eligibility filter first
- local-only first pass from memory/SQLite
- capped candidate set of 48 chats
- compact deterministic per-chat digests, not raw full chat payloads
- dedicated OpenAI reply-queue model path uses `gpt-5.4-mini`
- AI triage runs in 4 parallel batches of 12 chats
- progressive rendering of confident results while scanning continues
- recent-first ordering

Important current product rule:

- this is a dedicated reply-queue path, not generic semantic search

### SummaryEngine

File:

- [SummaryEngine.swift](/Users/pratyushrungta/telegraham/Sources/Search/SummaryEngine.swift)

Purpose:

- retrieval-first synthesis for prep and recap queries

Current behavior:

- retrieve relevant chats/messages first
- generate one bounded summary card
- render supporting result hits underneath
- time-range filtering is now applied before summary synthesis

## 4. AI Layer

Main files:

- [AIService.swift](/Users/pratyushrungta/telegraham/Sources/AI/AIService.swift)
- [AIProvider.swift](/Users/pratyushrungta/telegraham/Sources/AI/AIProvider.swift)
- [OpenAIProvider.swift](/Users/pratyushrungta/telegraham/Sources/AI/OpenAIProvider.swift)
- [ClaudeProvider.swift](/Users/pratyushrungta/telegraham/Sources/AI/ClaudeProvider.swift)

Current prompt files:

- [ReplyQueueTriagePrompt.swift](/Users/pratyushrungta/telegraham/Sources/AI/Prompts/ReplyQueueTriagePrompt.swift)
- [QuerySummaryPrompt.swift](/Users/pratyushrungta/telegraham/Sources/AI/Prompts/QuerySummaryPrompt.swift)

Design principle:

- AI should be used for judgment and synthesis
- local retrieval should do as much work as possible before AI is invoked
- reply queue uses a dedicated model path when needed, instead of inheriting the generic OpenAI default model blindly

## 5. Launcher UI

Main surface:

- [LauncherView.swift](/Users/pratyushrungta/telegraham/Sources/Views/LauncherView.swift)

Coordinator:

- [SearchCoordinator.swift](/Users/pratyushrungta/telegraham/Sources/Views/SearchCoordinator.swift)
- [SearchCoordinator+Agentic.swift](/Users/pratyushrungta/telegraham/Sources/Views/SearchCoordinator+Agentic.swift)

Current UI intent by family:

- exact lookup -> message-first rows
- topic search -> chat-first rows
- reply queue -> action-first rows
- summary -> summary card + supporting rows

Development/debug support exists, but normal launcher UI should stay focused on end-user results.

## Current Runtime Mapping

| Preferred engine | Current runtime behavior |
| --- | --- |
| `message_lookup` | dedicated `PatternSearchEngine` |
| `semantic_retrieval` | local semantic retrieval pipeline |
| `reply_triage` | dedicated `ReplyQueueEngine` for reply-queue queries; older agentic path still exists for non-reply agentic intents |
| `summarize` | dedicated `SummaryEngine` |
| `graph_crm` | recognized but unsupported in MVP runtime |

## Known Architectural Gaps

1. reply queue still leans too hard on local group heuristics in final validation, which can block AI from rescuing true group obligations
2. compact reply-queue digests can over-compress context and hide the original actionable ask in some threads
3. local-only reply triage can miss cold chats if recent updates have not been flushed locally yet
4. summary is still single-focus and not true cross-chat synthesis
5. graph/CRM execution is deferred to post-MVP
6. automated coverage for launcher/search/storage paths is still missing

## Recent Changes

### 2026-04-08

- made `messages` the durable local history table instead of a trim-to-50 disk cache
- kept hot recent-message behavior in memory, not in SQLite trimming paths
- stopped normal live/cache writes from mutating `sync_state`
- made cache invalidation memory-only instead of wiping chat history from disk
- verified live append and delete behavior against the real SQLite DB

### 2026-04-07

- added dedicated MVP engines for exact lookup, reply queue, and summary
- made query routing the source of truth for launcher execution
- changed reply queue to progressive rendering of confident rows
- changed reply queue ordering to recent-first
- hid heavy debug overlays from the main launcher UI

## Related Docs

- [Product PRD](/Users/pratyushrungta/telegraham/docs/product-prd.md)
- [Task Tracker](/Users/pratyushrungta/telegraham/docs/task-tracker.md)
- [Query Engine Matrix](/Users/pratyushrungta/telegraham/docs/query-engine-matrix.md)
