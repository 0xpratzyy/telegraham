# Multi-source Pidgy — architecture research

Researched 2026-07-26. Question: what has to change for Pidgy to ingest
Telegram + Gmail + Slack + WhatsApp into one memory that scales.

Two halves: **where the code actually stands** (measured, not guessed) and
**what the field has settled on** by mid-2026.

---

## 1. Where Pidgy stands today

Measured on this branch:

| Fact | Number |
|---|---|
| Swift files referencing `TelegramService` / `TGChat` / `TGMessage` / TDLib | **55 of 128 (43%)** |
| Worst-coupled layer | `Dashboard` — 14 files |
| Identity type everywhere | `Int64` **Telegram user id** |
| `messages` primary key | `(id, chat_id)` — both Telegram-shaped |

**The good news is bigger than it looks.** Three things are already right:

1. `messages` already carries `source TEXT NOT NULL DEFAULT 'telegram'` and
   `thread_root_id`. Nothing reads them yet — the column is a placeholder a
   past migration left — but the storage shape does not have to change to
   admit a second source.
2. The context layer is *conceptually* source-free already. A fact is
   `subject–predicate–object + provenance`. Nothing about "i_owe Akhil the
   invoice" is Telegram-specific; only the ids in `source_chat_id` /
   `source_message_id` are.
3. Onboarding already renders Telegram / Slack / Gmail tiles
   (`OnboardingConnectSteps`), with Slack and Gmail marked coming-soon.

**The real coupling is identity, not messages.** `facts.subject_person_id`
is documented as "canonical Telegram user id"; `person_profiles.user_id`
and `nodes.entity_id` are the same Telegram integer. A person who exists on
Telegram *and* Gmail *and* Slack has no representation at all today.

---

## 2. The four sources are not equally available

Ranked by what is actually possible, not by how much we want it:

| Source | Access | Sync primitive | Verdict |
|---|---|---|---|
| **Telegram** | TDLib, full personal account | update stream + `getChatHistory` | shipped |
| **Gmail** | Official API, OAuth | `historyId` cursor + `users.watch` → Pub/Sub push | **do this first** |
| **Slack** | Official API, OAuth | Events API push + Web API backfill | **do this second** |
| **WhatsApp** | ❌ no personal-account API | — | **do not build** |

### WhatsApp is a trap, and it should be said plainly

There is no sanctioned way to read a personal WhatsApp inbox. The Business
API is for businesses messaging customers — tiered sending limits, per
business-portfolio pacing, and no personal-history access. The unofficial
route (Baileys, whatsapp-web.js, WAHA) means driving WhatsApp Web with an
unofficial client, which Meta detects increasingly aggressively; a banned
number is not recoverable.

Shipping that inside a product means the failure mode is *the user loses
their WhatsApp account* — not "the integration is flaky". That is not a
risk to hand to a beta user. If WhatsApp is ever needed, the only defensible
paths are user-initiated chat export import (a file the user hands us) or
waiting for an official API.

**Recommendation: Telegram → Gmail → Slack. WhatsApp only via manual export.**

---

## 3. What the field settled on in 2026

Three findings from current benchmark work worth stealing:

**a) Memory is three stores, not one.** Episodic (what happened — the
messages), semantic (what is true — facts, entities, relations), procedural
(how this user works). Pidgy has episodic (`messages`) and semantic
(`facts`, `entity_summaries`) already. It has no procedural memory, and
`VoiceProfileService` is the seed of one.

**b) Retrieval must fuse THREE signals, not two.** The reported winner is
semantic similarity **+ keyword** **+ entity matching**, scored in parallel
and fused — entities extracted at write time into their own collection, and
query entities boosting matching memories at read time.

> **Measured, and it did not hold.** The claim above — that `facts` is the
> missing entity collection and wiring it in is the highest-value fix — was
> tested and is false for this corpus. As a fused score the entity signal
> made retrieval *worse* (21% vs 19% top-5 FTS-only); as its own recall arm
> its ceiling is 13%, meaning the right chat appears anywhere in the arm for
> 13 queries in 100 (`RetrievalRecallEval`). The reason is size, not wiring:
> `facts` holds 192 commitment rows across 1282 chats. It is a to-do store
> that happens to name people, not an entity collection.
>
> What the measurement found instead: no single signal is where the loss is.
> See "Where retrieval actually loses" below.

**c) Token budget is a first-class constraint.** Systems that answer in
~7k tokens/query are viable; ~26k is not. Every "just add more context"
instinct has to be checked against this.

**Named unsolved problems:** cross-session/cross-source identity
resolution, temporal abstraction at scale (~25% quality loss per 10×
history growth), and staleness of high-relevance facts. All three land on
Pidgy directly the moment a second source exists.

### Where retrieval actually loses, and why search has no AI in it

Every retrieval number recorded before 2026-07-29 measured top-1/top-5
precision of a fused candidate list that then went to an LLM reranker. Two
things came out of measuring it properly (`RetrievalRecallEval`, 100 labelled
queries over a 1282-chat corpus, plus live end-to-end runs):

| Stage | Rate |
|---|---|
| any retrieval arm surfaces the target at all | 71% |
| target reaches the top of the fused ranking (top-5) | ~19% |
| same, with the LLM reranker that used to run | ~21% |

**The reranker was removed.** Two points end-to-end does not pay for a network
round trip and a billed call on every search. Search is now local, instant, and
literal: FTS variants + vector hits, RRF-fused, shown. It finds what you typed
or it visibly finds nothing — both states a user can act on. Questions ("what's
on me", "latest with X") are answered by the fact/summary layer, which never
used this path.

Everything else tried against that 100-query set, and rejected:

1. **Candidate depth.** Raising the 50-message caps lifts the *reachable* set
   63% → 69% and buys zero improvement in what ranks into view — the weighted
   scorer ranks the extra chats straight back out. Depth is dead weight until
   the combiner is rank-based.
2. **`facts` as an entity arm.** The claim above — that wiring `facts` in is
   the highest-value fix — is false for this corpus. Ceiling 13%: 192
   commitment rows across 1282 chats. It is a to-do store that names people,
   not an entity collection.
3. **Summaries as a retrieval index.** 7% alone. They are document-shaped and
   only 71 of 1282 chats have one.
4. **Richer reranker evidence** (chat summary, then 3 matched messages instead
   of 1). Looked like it doubled top-5 on a 40-query sample; across all 100 it
   was 20% → 21% → 23%, inside noise. The 40-query sample was `prefix(40)` over
   a concatenated oracle list, which front-loads the easy buckets — sampling
   bias, not small n. This is the second metric artifact in one day to produce a
   confident wrong conclusion; the first was measuring precision where the
   pipeline needed recall.
5. **A stronger model.** GPT-5.6 Luna, routed to the rerank stage alone, lost
   all three evidence configurations (14/18/20% vs 20/21/23%) at 1.45× the wall
   clock, despite costing less per call.

**What the data still supports**, if search quality is revisited: rank-based
fusion instead of the weighted-sum scorer (measured 62% vs 58% at the wide end,
and it is what makes candidate depth worth anything), and summary coverage —
94% of chats have no rolling summary, which caps every summary-shaped idea
before it starts.

---

## 4. Target architecture

```
   Telegram(TDLib)   Gmail(OAuth)   Slack(OAuth)   [export importers]
         │                │              │                │
         └────────────────┴──────┬───────┴────────────────┘
                                 │   SourceAdapter protocol
                                 ▼
                    ┌─────────────────────────┐
                    │  canonical event store  │  messages(source, …)
                    │  + threads + accounts   │
                    └───────────┬─────────────┘
                                ▼
                    ┌─────────────────────────┐
                    │   identity graph        │  person ↔ many handles
                    └───────────┬─────────────┘
                                ▼
        ┌───────────────────────┴────────────────────────┐
        │   MEMORY                                       │
        │   episodic: messages + FTS + vectors           │
        │   semantic: facts + entity_summaries           │
        │   procedural: voice profile, habits            │
        └───────────────────────┬────────────────────────┘
                                ▼
            views: Reply queue · Tasks · Ask Pidgy · People
```

### 4.1 `SourceAdapter` — the one new protocol

Every source answers the same five questions. Nothing else in the app
should know a source exists.

```swift
protocol SourceAdapter: Sendable {
    var sourceId: String { get }              // "telegram" | "gmail" | "slack"
    func authenticate() async throws
    /// Newest-first page of conversations this account can see.
    func listConversations(cursor: SyncCursor?) async throws -> ConversationPage
    /// Messages for one conversation, forward from a cursor.
    func fetchMessages(conversationId: SourceID, after: SyncCursor?, limit: Int)
        async throws -> MessagePage
    /// Push/stream where the source supports it; polling fallback otherwise.
    func liveUpdates() -> AsyncStream<SourceEvent>
}
```

Per-source sync primitives hide behind `SyncCursor`: Telegram = message id,
Gmail = `historyId` (expires ~1 week → full resync path is mandatory, not
optional), Slack = `ts` + Events API.

### 4.2 Canonical ids — the breaking change worth doing once

Today `(id, chat_id)` are Telegram integers. Two sources will collide.

```
account(id, source, external_account_id, display_name)      -- one per connected login
conversation(id, account_id, external_id, kind, title)       -- chat | channel | thread | label
message(id, conversation_id, external_id, sender_handle_id, date, text, …)
handle(id, source, external_id, display_name)                -- one identity AS SEEN BY one source
person(id, display_name)                                     -- the human
person_handle(person_id, handle_id, confidence, evidence)    -- the join that makes it multi-source
```

`person_handle` is where the hard problem lives, and the honest design is
that it is **evidence-backed and reversible**: auto-merge only on strong
signals (same verified email, same phone, OAuth-provided identity), suggest
on weak ones (same display name + overlapping counterparties), and let the
user confirm. Never silently merge two humans — an unmergeable mistake is
worse than a missed merge.

### 4.3 What the memory layer inherits

Facts already carry provenance; they gain `source` and point at
`conversation_id` instead of a Telegram `chat_id`. The projections
(`FactProjection.replyLanes`, `tasks`) need **no change at all** — which is
the payoff of the July refactor. `pidgy://chat/<id>` deep links become
`pidgy://open/<source>/<conversation>/<message>` with per-source URL
builders.

---

## 5. Migration plan

Ordered so each phase ships something and nothing is a big-bang rewrite.

**Phase 0 — retrieval fix (do first, unrelated to sources).**
~~Add entity matching as the third retrieval signal.~~ Superseded by
measurement; see "Where retrieval actually loses" below. The remaining
Phase 0 is closed: the AI reranker was measured at +2 points and removed, and
search is now local and instant. If search quality is revisited before adding
sources, the two measured levers are rank-based fusion and summary coverage —
not another retrieval signal.

**Phase 1 — canonical schema, still Telegram-only.**
Introduce `account` / `conversation` / `handle` / `person` / `person_handle`
and migrate Telegram data into them. Ship with exactly one adapter. Success
test: the app behaves identically, and `grep -rl TelegramService Sources/`
drops from 55 files toward ~10 (adapters + onboarding).

**Phase 2 — `SourceAdapter` + Gmail.**
Gmail is the best second source: official API, clean OAuth, a real cursor,
and email threads map onto the fact model without strain ("I owe Rakesh the
proposal" reads the same from an email as from a DM). Identity is *easier*
here — email addresses are strong join keys.

**Phase 3 — Slack.**
Adds workspace/channel scoping and a second OAuth. Reuses everything.

**Phase 4 — cross-source intelligence.**
Only once two real sources exist: one loop tracked across sources (asked on
Slack, answered by email), person pages that merge handles, dedup of the
same thread forwarded twice.

**WhatsApp** stays out of all phases until an official API exists, or ships
as an export-file importer that touches no account.

---

## 6. Risks that will actually bite

| Risk | Mitigation |
|---|---|
| Email volume dwarfs chat (10–100× messages) | Per-source extraction budgets; newsletters/notifications must be classified out *before* AI spend, not after |
| Cost scales linearly with sources | Extraction is per-window AI; a second source doubles the bill. Gate by conversation importance, not by "everything" |
| Wrong identity merge | Evidence-backed `person_handle` with confidence + user confirmation; always reversible |
| Temporal decay (~25% loss per 10× history) | Rolling `entity_summaries` already exist — they must become the primary read path for old history instead of raw messages |
| 43% of files know about Telegram | Phase 1 exists specifically to pay this down before the second source, not after |

---

## 7. The one-line answer

**Fix retrieval first (31% → target), then make the schema source-neutral
while still on Telegram, then add Gmail, then Slack. Skip WhatsApp — there
is no sanctioned personal API and the failure mode is the user's account.**
