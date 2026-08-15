# Pidgy product-design audit

Date: 2026-08-15 (Asia/Dubai)

Scope assumption: the core triage loop — Home → Reply queue → Tasks → evidence inspector — across Gmail, Slack, Telegram, and WhatsApp.

## Overall verdict

Pidgy has a strong foundation for a calm, source-aware command center: the Home brief, queue segmentation, compact inspectors, and explicit Gmail preview CTA all make the main loop understandable. The experience is not yet consistently trustworthy because urgency semantics, source identity, and action summaries change from screen to screen. The highest-value work is to normalize identity and urgency, then make every item explain the next action in one glance.

## Step 1 — Home

![Step 1 — Home](/Users/pratyushrungta/telegraham/.claude/worktrees/great-raman-d7635d/.codex/audits/2026-08-15-pidgy/01-home.png)

Health: Needs work, with a good briefing pattern.

Strengths:

- Clear hierarchy: greeting, “Needs you now”, “Up next”, and one prominent Ask Pidgy entry point.
- Cross-source rows are scannable because WhatsApp, Gmail, and Slack are visibly tagged.
- Rows use people or sender identity plus a concise action rather than raw message bodies.

Risks:

- “I found 27 things that need you now” is not reconciled with visible age values of 1–2 days, or with the larger Reply queue/Tasks counts. “Now” needs an explicit urgency rule or a due-time explanation.
- The Ask Pidgy copy names Gmail, Slack, and Telegram but omits WhatsApp even though WhatsApp is present immediately below.
- The VAT Consultant row exposes the raw WhatsApp ID `120363423799511145`; this is noisy and makes the source feel untrusted. Use one canonical display name and keep IDs hidden.
- Large decorative space and the owl strip push the actionable list down without adding triage information.
- Rows have no visible primary action or “why this is here” cue; the selection state is only a grey background.

Accessibility risks:

- Secondary metadata and source labels are grey on dark; contrast needs measurement rather than visual assumption.
- Selection has no obvious non-color marker.
- The Ask Pidgy arrow is small and visually inactive compared with the large card.

## Step 2 — Reply queue

![Step 2 — Reply queue](/Users/pratyushrungta/telegraham/.claude/worktrees/great-raman-d7635d/.codex/audits/2026-08-15-pidgy/02-reply-queue.png)

Health: Good foundation, but semantics need tightening.

Strengths:

- “On me / On them / Quiet” plus Newest and Search gives the queue a useful working rhythm.
- The selected Slack item keeps the suggested action, assist actions, evidence, and Open in Slack CTA in one inspector.
- Evidence is compact enough to preserve context without opening Slack.

Risks:

- “On me”, “On them”, and “Quiet” are not self-explanatory to a first-time user; a short helper label or tooltip is needed.
- Quiet is included in the overall queue count even though it is intentionally non-urgent, which weakens the meaning of “Chats that need attention”.
- Some rows show a source tag and others do not, so the scanning rule is inconsistent.
- The suggested action repeats the row label; the inspector should add the missing context or decision, not restate it.

Accessibility risks:

- The selected tab relies primarily on a filled background; retain the text state and add a stronger focus/selection treatment.
- Keyboard focus, VoiceOver labels, and scroll behavior for the evidence list were not verifiable from screenshots.

## Step 3 — Tasks

![Step 3 — Tasks](/Users/pratyushrungta/telegraham/.claude/worktrees/great-raman-d7635d/.codex/audits/2026-08-15-pidgy/03-tasks.png)

Health: Fair; the list is understandable but underpowered for 83 open tasks.

Strengths:

- Open/Done/All counts are immediately visible.
- Task titles are action-oriented and easier to scan than source subjects.
- Gmail and WhatsApp tasks carry visible source tags.

Risks:

- The header says “Extracted from chat” even while the list includes Gmail and WhatsApp; this is a credibility-breaking label mismatch.
- The list has substantial unused horizontal space but no search, sort, assignee, or due-date affordance in this state. Age alone does not explain ordering.
- There is no visible reason why “Ban @DaveChez from the TG” outranks a 17-hour Node.js migration or a 19-hour bank task.
- Source metadata is missing on some rows, making mixed-source triage inconsistent.

Accessibility risks:

- Long scrolling lists need a clear keyboard/focus model and stable row semantics; neither can be verified from a static capture.

## Step 4 — WhatsApp task inspector

![Step 4 — WhatsApp evidence inspector](/Users/pratyushrungta/telegraham/.claude/worktrees/great-raman-d7635d/.codex/audits/2026-08-15-pidgy/04-task-inspector.png)

Health: Strong evidence pattern, weak semantic summary.

Strengths:

- The inspector clearly separates source identity, Summary, and Evidence.
- Fifteen context messages are shown with the source message highlighted, which supports verification without leaving Pidgy.
- “You” messages and participant names make the conversation useful as evidence.

Risks:

- The summary is generic (“raised this in WhatsApp… Open the source”) and does not explain the actual payment-link decision.
- The title uses “Pay THE VAT CONSULTANT invoice link”, while the evidence uses “TVC”; canonical naming should be applied across row, inspector, and thread header.
- A participant/group display photo and full conversation name should be stable across all WhatsApp surfaces.

Accessibility risks:

- The source message is differentiated by a blue rail/background; add a text label and a stronger focus state so meaning is not color-dependent.

## Step 5 — Gmail task inspector

![Step 5 — Gmail task inspector](/Users/pratyushrungta/telegraham/.claude/worktrees/great-raman-d7635d/.codex/audits/2026-08-15-pidgy/05-gmail-inspector.png)

Health: Strongest of the inspected detail states.

Strengths:

- Multi-account identity is explicit (`pratyush987@gmail.com`) without opening Gmail.
- The summary is concrete: it names the Node.js 20 deprecation, deadline, consequence, and next action.
- “Preview email” and “Open” are clear, read-only-friendly CTAs.

Risks:

- The account email is visually prominent enough to compete with the sender and task title; it can be secondary metadata unless disambiguation is needed.
- The inspector still depends on a generic title/summary pairing; the next step could be surfaced as a short action chip or deadline line.

Accessibility risks:

- The preview/open button labels are clear, but focus order and screen-reader grouping are unverified.

## Step 6 — Gmail preview modal

![Step 6 — Gmail preview modal](/Users/pratyushrungta/telegraham/.claude/worktrees/great-raman-d7635d/.codex/audits/2026-08-15-pidgy/06-gmail-preview.png)

Health: Good pattern with modal polish still needed.

Strengths:

- Original email content is behind an explicit CTA instead of being dumped into the inspector.
- Remote images and tracking are visibly blocked, which is a strong privacy default.
- The rendered body preserves links, paragraphs, and lists in a readable layout.

Risks:

- The modal removes most surrounding context; the header should explicitly say “Email preview” and retain a compact task/source breadcrumb.
- A blank image placeholder appears near the top of the body, which reads like a broken asset rather than an intentional blocked-content state.
- The modal’s long body needs a clearly discoverable scroll region and a consistent “Open in Gmail” escape hatch.

Accessibility risks:

- Screenshot evidence cannot verify focus trapping, Escape-to-close, VoiceOver announcement, or keyboard traversal of links.

## Prioritized recommendations

1. Normalize source identity everywhere. Hide raw WhatsApp IDs, keep canonical display names, and expose account/group disambiguation as secondary metadata.
2. Define a deterministic urgency contract. Reserve “Needs you now” for actionable/urgent items, move waiting or multi-day items to “Up next”, and show why an item is ranked.
3. Make summaries source-aware and action-first. Replace “raised this in…” fallback copy with verb + object + deadline/decision, using the same summary contract across Home and inspectors.
4. Make source tagging consistent. Every mixed-source row should show a source tag, or none should; change “Extracted from chat” to “Extracted from connected sources”.
5. Add lightweight list controls to Tasks: search, newest/oldest, source, and assignee/“For me”. Keep Open/Done/All counts as the stable state model.
6. Keep the current evidence pattern, but add full thread/channel identity, stable participant avatars, and a text label for the highlighted source message.
7. Reduce decorative/empty space on Home and Tasks until the actionable list is visible sooner; retain the owl motif as a compact brand accent.
8. Finish Gmail preview with an intentional blocked-media placeholder, explicit modal title, visible scroll affordance, and keyboard/focus verification.

## Evidence limits

- This is a screenshot-based product audit of the current local build; it is not a sync, classifier, or extraction-quality evaluation.
- I did not verify keyboard traversal, focus rings, VoiceOver labels, contrast ratios, zoom, reduced motion, or dynamic type.
- I did not test search, sort, queue tabs, Open/Mark done, or modal close behavior beyond opening the captured preview state.
- The audit uses fresh captures from the running app at 15:31–15:36 local time; prior screenshots and memory were not used as evidence.

