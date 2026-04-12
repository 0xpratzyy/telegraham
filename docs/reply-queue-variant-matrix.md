# Reply Queue Variant Matrix

Last updated: 2026-04-12

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

## Digest Variants

These are the evidence packages sent per chat.

| Digest | What it adds | Main purpose |
| --- | --- | --- |
| `compact_v1` | local signal, pipeline hint, recent snippets | weakest compact baseline |
| `digest_v2` | actionable inbound, closure, commitment, handle mentions | first real structured ownership layer |
| `digest_v3` | `groupOwnershipHint`, broadcast-vs-direct, inbound owns next step | strong group reasoning |
| `digest_v4` | reframes local heuristic fields as weak/noisy metadata | cleaner prompt behavior on noisy chats |
| `digest_v5` | `privateOwnershipHint`, `privateReplySignal`, wider private snippet window | best overall DM + group balance |

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

## Practical Recommendation

### Best shipping candidate

- **Prompt**: `field_aware_groups_v3_private_recall_v2`
- **Digest**: `digest_v5`

Why:

- best overall strict quality
- zero bad group false positives in the main robustness sweep
- best stability
- strong enough DM recall without reopening old group spam

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

