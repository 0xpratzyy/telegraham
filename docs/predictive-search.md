# Predictive quick matches

Inspired by [Nader Dabit's Jev launcher demo](https://x.com/dabit3/status/2100756930054504776)
and its [reference implementation](https://github.com/dabit3/jev-experiments/tree/main/jev-launcher).
Implemented independently for Pidgy conversations, not as a Mac-wide app/file launcher.

## Behavior

With TypeSafe enabled, normal launcher search immediately shows lexical matches
from eligible chat titles and recent message snippets. After a 150 ms typing pause,
Local indexed-history retrieval adds matching older messages, then Jev chooses among at most 15 candidates using two typed questions: target and
whether the visible evidence is unambiguous. A confident choice moves to the top.
No generated names, model-authored links, system toggles or automatic execution.

Candidates combine title matches, up to ten historical conversation matches and recent eligible chats. Chat
source, DM/group scope, bot preference, pipeline filter and parsed date bounds are
applied before sending. Titles are capped at 120 characters, snippets at 400.
The candidate list contains bounded message excerpts, not full transcripts or arbitrary Downloads files.
The existing full-search pipeline independently handles broader semantic retrieval and facts.

The original full-query planner remains enabled, with its 300 ms debounce moved
before the paid call. Jev's preview does not block it or replace summary generation.
Final full-search results, summary output and errors take precedence over previews.

Each query cancels previous prediction work and changes a generation identifier;
late responses cannot overwrite newer input. Arrow-key navigation freezes quick
matches and cancels the pending full search, preventing an Enter target from moving.
New input resumes search. Requests use a 1.2-second URLSession request timeout.
HTTP failures, ambiguity, malformed output and missing evidence retain local order.

Prediction target probability must be >=0.85, with >=0.25 margin, and readiness
must be >=0.80. These are thresholds, not calibrated accuracy guarantees. Up to 32
positive decisions are cached for 30 seconds using query plus the entire candidate
snapshot; changed content/scope cannot reuse an old mapping. Disable TypeSafe in
Preferences to restore the original search behavior. Usage appears as Predictive Search.

## Validation, September 18, 2026

31 selected tests passed, including one opt-in live test. Coverage includes immediate
local results, promotion, caching, changed candidates, scope/date bounds, API failures,
disconnect, rapid typing, cancellation, keyboard freezing and original query routing.

Live fixture: 10 queries repeated twice over three synthetic conversations. English,
Hinglish, semantic paraphrases, unknown topics and summary requests were included.
No private message history was used.

- Median model round trip: **406 ms**, excluding the 150 ms typing debounce.
- Range: **371-1,297 ms**, including the initial cold connection.
- **14 confident promotions, all correct**.
- Four expected abstentions (unknown topic and summary request, repeated twice).
- Two additional abstentions on `where is the ready deck`; local matching retained
  the correct chat. Thus exact prediction expectations passed **18/20**.
- Reported token cost across 20 calls: **$0.000610512**, approximately $0.0305 per
  1,000 requests of this size. This excludes full search and uses the existing
  TypeSafe $0.042/M input-token price. Larger candidate lists and typing patterns
  change cost. Canceled requests without returned usage may still be billed upstream.

The demo author's ~100 ms on their machine is not a measured Pidgy claim. These
fixtures are small, repeated synthetic cases, not production accuracy evidence.
Raw measurements: `Build/TypeSafeBenchmark/predictive-results.json`.

To repeat with the saved key, close Pidgy and run:

```sh
TEST_RUNNER_PIDGY_LIVE_PREDICTIVE_BENCHMARK=1 xcodebuild \
  -project Pidgy.xcodeproj -scheme Pidgy -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/pidgy-codex-derived \
  -clonedSourcePackagesDirPath /private/tmp/pidgy-source-packages \
  -only-testing:PidgyTests/PredictiveSearchTests test
```

Normal tests skip live API calls. Build/launch with `./script/build_and_run.sh --verify`.


## Indexed history upgrade (September 18)

Quick matches now retrieve up to 100 local FTS hits after the typing debounce,
scoped to eligible chats and the requested date range before the SQL limit.
Up to ten conversations with historical evidence join title matches, capped at
15 candidates for Jev. Attachment filenames, captions and OCR are searchable
when those strings are present in the message index; this does not add PDF body
extraction. Matching snippets are centered near a query term and capped at 400
characters. History rows show their message timestamp and open the conversation.
Exact-message navigation is not implemented by this change.

Cancellation and keyboard selection invalidate both archive retrieval and model
responses. The short-lived ranking cache includes message identity and evidence.
The independent full search still handles semantic retrieval beyond these bounded
keyword candidates. No changes were made to reply-queue ownership.

A read-only local FTS probe across invoice, launch and PDF queries (five runs each)
measured 0.24 ms median, 0.03–49.30 ms range. This excludes model time, UI work and
the typing debounce; it is not an end-to-end latency claim.
