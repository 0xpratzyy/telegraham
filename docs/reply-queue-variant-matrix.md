# Reply Queue Variant Matrix

Last updated: 2026-04-14

This is the canonical reference for reply-queue prompt variants, digest variants, and how they performed in offline evaluation.

## What A Variant Is

A reply-queue variant has three parts:

1. **User input**
   - what the user types, for example `who do I need to reply to`
2. **Prompt**
   - the hidden system instructions that tell the model how to judge responsibility
3. **Digest**
   - the structured per-chat state summary we send as evidence

The model under test is held constant in these comparisons:

- `gpt-5.4-mini`
- `4x12` parallel batching

## What Variants Are Compared Against

Every reply-queue variant is compared in three ways:

1. **Against other variants**
   - same model
   - same batching
   - same candidate snapshots
2. **Against the single-snapshot gold benchmark**
   - [reply_queue_manual_gold_mixed_recent_48.json](/Users/pratyushrungta/telegraham/evals/reply_queue_manual_gold_mixed_recent_48.json)
3. **Against the broader multi-snapshot oracle**
   - [reply_queue_manual_oracle_v1.json](/Users/pratyushrungta/telegraham/evals/reply_queue_manual_oracle_v1.json)

Main harness/report files:

- [reply_queue_variant_bench.py](/Users/pratyushrungta/telegraham/tools/reply_queue_variant_bench.py)
- [reply_queue_harness.py](/Users/pratyushrungta/telegraham/tools/reply_queue_harness.py)
- [reply_queue_oracle_bench.py](/Users/pratyushrungta/telegraham/tools/reply_queue_oracle_bench.py)
- [20260412-083641 harness report](/Users/pratyushrungta/Library/Application%20Support/Pidgy/debug/reply_queue_harness/20260412-083641/report.json)
- [20260412-094813 oracle report](/Users/pratyushrungta/Library/Application%20Support/Pidgy/debug/reply_queue_oracle_bench/20260412-094813/report.json)

## Prompt Families

These are the main reasoning styles currently implemented.

| Prompt family | Intent | Key judgment style |
| --- | --- | --- |
| `baseline` | generic reply triage | plain unresolved-ask judgment with minimal structure |
| `strict_groups_v1` | reduce group noise | default groups to `quiet` unless ownership is clearly on the user |
| `field_aware_groups_v2` | improve group ownership | trust `groupOwnershipHint` and handle mentions more strongly |
| `field_aware_groups_v3` | improve group precision further | treat ownership hints as primary and local heuristic fields as noisy |
| `field_aware_groups_v4_contextual_recovery_v1` | recover borderline real group obligations | distinguish explanation-style replies from real asks and let earlier requests-for-input rescue later task dumps |
| `field_aware_groups_v5_tiered_review_v1` | add a secondary surfaced bucket | allow stale-but-real open loops to surface as `worth_checking` instead of forcing `on_me` vs `quiet` |
| `private_recall_v1` | recover terse DMs | allow short private operational asks to remain `on_me` |
| `private_recall_v2` | best DM recovery so far | use explicit private ownership fields and wider private snippets without reopening group spam |

### Prompt Details

#### `baseline`

Uses only the shared base prompt:

- decide `on_me`, `on_them`, `quiet`, or `need_more`
- prefer concrete unresolved asks
- do not keep answered asks as `on_me`

#### `strict_groups_v1`

Adds group-specific rules:

- default group chats to `quiet` unless ownership is clear
- if a message names another person or handle, assume it is aimed at them
- broad coordination chatter should usually be `quiet`

#### `field_aware_groups_v2`

Adds ownership-aware reasoning:

- treat `groupOwnershipHint` as the strongest clue for groups
- if ownership hints say `mentioned_other_handle`, `broadcast_group_question`, `closed_after_actionable`, `waiting_on_them`, or `no_clear_actionable_ask`, do not return `on_me` unless snippets clearly reopen it
- preserve stronger private-chat candidates

#### `field_aware_groups_v3`

Same core direction as `v2`, but stricter:

- treat `groupOwnershipHint` as the main ownership signal
- treat `weakLocalHeuristic` as noisy metadata only
- if latest actionable text is broadcast-style and not direct second person, default to `quiet`
- if a later closure signal appears after the ask, prefer `quiet` or `on_them`

#### `private_recall_v1`

Adds DM recovery on top of group ownership logic:

- recover short private asks like `try it`, `check once`, `let me know`, `share feedback`
- do not require a question mark for private operational follow-ups

#### `private_recall_v2`

Strongest current DM handling:

- use `privateOwnershipHint` as a strong cue
- `private_direct_follow_up` usually leans `on_me`
- `private_waiting_on_them` leans `on_them`
- `private_closed` leans `quiet`
- `privateReplySignal` helps recover short operational follow-ups without overriding clear closure

#### `field_aware_groups_v4_contextual_recovery_v1`

Adds a narrower recovery rule set on top of the structured ownership approach:

- treat explanatory technical replies in groups as likely `quiet`
- treat cc-style handle mentions as weaker than real assignment
- allow an earlier explicit request for input to keep a later task dump alive
- still preserve the `privateOwnershipHint` rules from `private_recall_v2`

#### `field_aware_groups_v5_tiered_review_v1`

Adds a benchmark-only middle bucket:

- `on_me` means reply-now
- `worth_checking` means a real but stale/diluted open loop that should surface in a secondary section
- `quiet` still hides ambient or closed chatter

## Digest Variants

These are the evidence packages sent per chat.

| Digest | What it adds | Main purpose |
| --- | --- | --- |
| `compact_v1` | local signal, pipeline hint, recent snippets | weakest compact baseline |
| `digest_v2` | actionable inbound, closure, commitment, handle mentions | first real structured ownership layer |
| `digest_v3` | `groupOwnershipHint`, broadcast-vs-direct, inbound owns next step | strong group reasoning |
| `digest_v4` | reframes local heuristic fields as weak/noisy metadata | cleaner prompt behavior on noisy chats |
| `digest_v5` | `privateOwnershipHint`, `privateReplySignal`, wider private snippet window | best overall DM + group balance |
| `digest_v6` | `digest_v5` plus wider group context and targeted group recovery fields | benchmark branch for `Banko`-vs-`Inner Circle` style tradeoffs |

### Important Fields By Digest

#### `compact_v1`

- `localSignal`
- `pipelineHint`
- `replyOwed`
- `strictReplySignal`
- `effectiveGroupReplySignal`
- a few recent snippets

#### `digest_v2`

Adds:

- `latestSpeaker`
- `latestInboundSpeaker`
- `latestOutboundExists`
- `latestActionableInboundSpeaker`
- `latestActionableInboundMentionsHandles`
- `latestCommitmentFromMe`
- `closureAfterLatestActionable`
- `latestActionableStillAfterMyReply`
- `latestActionableInboundText`
- `latestCommitmentText`
- `latestClosureText`

#### `digest_v3`

Adds stronger group fields:

- `groupOwnershipHint`
- `broadcastStyleLatestActionable`
- `directSecondPersonLatestActionable`
- `latestInboundOwnsNextStep`

#### `digest_v4`

Same general evidence as `digest_v3`, but changes framing:

- collapses the local heuristic bundle into `weakLocalHeuristic`
- tells the model not to over-trust those local signals

#### `digest_v5`

Adds stronger private-chat evidence:

- `privateOwnershipHint`
- `privateReplySignal`
- wider private snippet selection around the latest actionable private message

#### `digest_v6`

Keeps the private-chat behavior of `digest_v5`, then adds group-specific evidence:

- wider pre-actionable group context window
- `explicitSecondPersonLatestActionable`
- `latestActionableLooksExplanatory`
- `ccStyleHandleMentions`
- `earlierRequestForInputExists`
- `earlierRequestForInputText`

## Best Performing Variants

These are from the main robustness sweep:

- [20260412-083641 harness report](/Users/pratyushrungta/Library/Application%20Support/Pidgy/debug/reply_queue_harness/20260412-083641/report.json)

| Variant | Prompt family | Digest | Strict F1 | Lenient F1 | Group lenient F1 | Max group FP | Median latency |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| `field_aware_groups_v3_private_recall_v2_digest_v5_digest_v5_4x12` | `field_aware_groups_v3_private_recall_v2` | `digest_v5` | `0.857` | `0.875` | `0.667` | `0` | `5604ms` |
| `field_aware_groups_v3_private_recall_v2_digest_v5_digest_v3_4x12` | `field_aware_groups_v3_private_recall_v2` | `digest_v3` | `0.804` | `0.882` | `0.733` | `1` | `6436ms` |
| `field_aware_groups_v2_private_recall_v1_digest_v3_digest_v5_4x12` | `field_aware_groups_v2_private_recall_v1` | `digest_v5` | `0.804` | `0.826` | `0.583` | `1` | `7431ms` |
| `field_aware_groups_v2_digest_v3_digest_v5_4x12` | `field_aware_groups_v2_digest_v3` | `digest_v5` | `0.800` | `0.824` | `0.500` | `1` | `5786ms` |
| `field_aware_groups_v3_private_recall_v1_digest_v4_digest_v5_4x12` | `field_aware_groups_v3_private_recall_v1` | `digest_v5` | `0.785` | `0.812` | `0.583` | `1` | `6089ms` |
| `field_aware_groups_v3_digest_v4_digest_v3_4x12` | `field_aware_groups_v3_digest_v4` | `digest_v3` | `0.775` | `0.915` | `0.900` | `1` | `6177ms` |
| `baseline_compact_v1_4x12` | `baseline` | `compact_v1` | `0.534` | `0.653` | `0.422` | `6` | `6819ms` |

## Broader Oracle Read

From the multi-snapshot oracle run:

- [20260412-094813 oracle report](/Users/pratyushrungta/Library/Application%20Support/Pidgy/debug/reply_queue_oracle_bench/20260412-094813/report.json)

The same winner still came out on top:

- `field_aware_groups_v3_private_recall_v2_digest_v5_digest_v5_4x12`

The absolute scores dropped under the broader oracle. That is expected and healthy:

- the benchmark became broader and harsher
- it exposed brittleness across alternate candidate orderings
- but the same variant still remained the best overall candidate

## Apr 12 Group-Focused Oracle Read

From the fresher Apr 12 snapshot oracle:

- [reply_queue_group_precision_oracle_v1.json](/Users/pratyushrungta/telegraham/evals/reply_queue_group_precision_oracle_v1.json)
- [20260414-194348 oracle report](/Users/pratyushrungta/Library/Application%20Support/Pidgy/debug/reply_queue_oracle_bench/20260414-194348/report.json)

This harsher oracle was built to answer a narrower question:

- are we still reopening obviously closed or ambient group chats on fresher live candidates
- can we rescue borderline group obligations without bringing the spam back

What it showed:

- `baseline_compact_v1_4x12` is still clearly too noisy
- `field_aware_groups_v3_private_recall_v2_digest_v5_digest_v5_4x12` still wins overall
- `field_aware_groups_v3_private_recall_v2_digest_v5_digest_v3_4x12` gets a bit more recall on some snapshots, but it is less stable and peaks at more group false positives

The important new failure pattern is narrower now:

- baseline still revives obvious bad group results like `AI Weekends <> Inner Circle`, `First Dollar`, and `Inner Circle`
- the top two structured variants mostly converge on the same remaining problem pair:
  - false positive: `Inner Circle`
  - lenient miss: `Banko`

That is useful because it means the benchmark frontier has moved:

- we are no longer fighting broad noisy group spam
- we are now tuning a smaller tradeoff between one recurring false positive and one borderline missed obligation

So the next benchmark target is not “general group precision” in the abstract. It is:

- recover `Banko`-style maybe-on-you groups
- without reopening `Inner Circle`-style ambient technical chatter

## Follow-up Group Oracle Read

After the first Apr 12 oracle exposed the `Banko` vs `Inner Circle` tradeoff, the next benchmark loop added:

- [reply_queue_group_fp_traps_oracle_v1.json](/Users/pratyushrungta/telegraham/evals/reply_queue_group_fp_traps_oracle_v1.json)
- `digest_v6`
- `field_aware_groups_v4_contextual_recovery_v1`

Recent reports:

- [20260414-200619 fresh-group oracle report](/Users/pratyushrungta/Library/Application%20Support/Pidgy/debug/reply_queue_oracle_bench/20260414-200619/report.json)
- [20260414-200826 trap-oracle report](/Users/pratyushrungta/Library/Application%20Support/Pidgy/debug/reply_queue_oracle_bench/20260414-200826/report.json)
- [20260414-203231 broader-oracle comparison](/Users/pratyushrungta/Library/Application%20Support/Pidgy/debug/reply_queue_oracle_bench/20260414-203231/report.json)

What changed:

- `digest_v6` now carries the earlier `gib more input` style request into the prompt
- explanation-style group messages like `you mean to get the code...` are marked separately from real asks
- cc-style mentions are separated from true task assignment

What the new runs showed:

- `field_aware_groups_v4_contextual_recovery_v1 + digest_v6` wins the fresh Apr 12 oracle and cleanly resolves the original `Banko` vs `Inner Circle` pair
- that same contextual prompt still overreaches on some broader slices, for example reopening `First Dollar` on the fresh oracle and not winning the older trap oracle
- `field_aware_groups_v3_private_recall_v2 + digest_v6` is the steadier broad candidate right now:
  - it wins the older trap oracle
  - it narrowly beats the current `digest_v5` shipping candidate on the broader multi-snapshot oracle
  - it does this while keeping zero majority group false positives in those broader runs

So the benchmark result is now split in a useful way:

- `v4 + digest_v6` is the sharper research branch for fresh real group obligations
- `v3 private_recall_v2 + digest_v6` is the safer next broad candidate if we want one script-side winner to keep testing before product promotion

## Tiered Review Read

The next benchmark loop changed the framing itself:

- [20260414-205455 fresh-group tiered report](/Users/pratyushrungta/Library/Application%20Support/Pidgy/debug/reply_queue_oracle_bench/20260414-205455/report.json)
- [20260414-205622 trap-oracle tiered report](/Users/pratyushrungta/Library/Application%20Support/Pidgy/debug/reply_queue_oracle_bench/20260414-205622/report.json)
- [20260414-213241 fresh-group tiered rerun after closure fixes](/Users/pratyushrungta/Library/Application%20Support/Pidgy/debug/reply_queue_oracle_bench/20260414-213241/report.json)
- [20260414-213248 trap-oracle tiered rerun after closure fixes](/Users/pratyushrungta/Library/Application%20Support/Pidgy/debug/reply_queue_oracle_bench/20260414-213248/report.json)

What changed:

- the scorer now supports a benchmark-only `worth_checking` surfaced bucket
- `maybe` labels are normalized into that same secondary bucket during evaluation
- `Banko` is now modeled as `worth_checking`, not forced into `on_me` vs `not_on_me`

What it showed:

- `field_aware_groups_v5_tiered_review_v1 + digest_v6` is the first variant that consistently surfaces `Banko` as a secondary item while keeping `Inner Circle` quiet
- after teaching the harness that phrases like `Already added` are real closure/ownership handoff signals, the same tiered branch now suppresses `Bhavyam <> First Dollar` cleanly on the older trap oracle and keeps `Banko` surfaced as `worth_checking`
- the stricter `field_aware_groups_v6_tiered_review_v2 + digest_v6` experiment removed more trap-side noise but over-corrected on fresh snapshots by reopening cases like `Tom🔥` or `Inner Circle`
- the main remaining tiered leak is `onchain accountability` on one audit-order snapshot, so the surfaced bucket is much cleaner but not perfectly solved yet

So the benchmark answer is:

- the tiered framing is directionally better for human trust
- the best current tiered branch is now good enough to keep testing benchmark-side
- but the `worth_checking` bucket still needs one more precision pass before product promotion

## Practical Recommendation

### Best shipping candidate

- **Prompt**: `field_aware_groups_v3_private_recall_v2`
- **Digest**: `digest_v5`

Why:

- best overall strict quality
- zero bad group false positives in the main robustness sweep
- best stability
- strong enough DM recall without reopening old group spam

### Best current broad research candidate

- **Prompt**: `field_aware_groups_v3_private_recall_v2`
- **Digest**: `digest_v6`

Why:

- same private-recall framing as the current shipping candidate
- better benchmark coverage for explanation-style technical groups and cc-style mentions
- currently the safer broad winner across the newer trap and broader oracle comparisons

### Best tiered research candidate

- **Prompt**: `field_aware_groups_v5_tiered_review_v1`
- **Digest**: `digest_v6`

Why:

- best match so far for `show it, but don’t overclaim it`
- correctly surfaces `Banko` as a secondary review item instead of a forced `on_me`
- closure-heuristic fixes now suppress older resolved group asks like `Bhavyam <> First Dollar`
- still not clean enough to ship because the surfaced bucket can reopen stale accountability-style rows on some audit-order snapshots

### Best fresh-group research branch

- **Prompt**: `field_aware_groups_v4_contextual_recovery_v1`
- **Digest**: `digest_v6`

Why:

- best direct answer so far to the `Banko` vs `Inner Circle` failure pair
- but still not broad enough or stable enough to call the universal winner

### Best looser alternative

- **Prompt**: `field_aware_groups_v3_private_recall_v2`
- **Digest**: `digest_v3`

Why:

- better group lenient recall
- but reintroduces some group false-positive risk

### What not to ship

- `baseline + compact_v1`
- `strict_groups_v1 + compact_v1`

These variants are too noisy and are clearly dominated by the structured field-aware families.

## Rule Of Thumb

- **Prompt** decides how to reason
- **Digest** decides what evidence the model gets

For reply queue, the current best pattern is:

- strong ownership-aware prompt
- rich structured digest
- skepticism toward noisy local heuristics
