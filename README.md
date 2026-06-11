# Pidgy

Local-first Telegram command center for replies, tasks, people, topics, and search. Native macOS, SwiftUI, TDLib.

## For developers — building from source

### Prerequisites

- macOS 26+, Xcode 17+
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- A Telegram api_id / api_hash from <https://my.telegram.org/apps>
- An OpenAI API key (default model is `gpt-5.4-mini`) or an Anthropic Claude key

### One-time setup

```bash
# 1. Drop your beta credentials into a gitignored file. The .template lists
#    the exact variable names and where each value comes from.
cp Config/BetaSecrets.local.xcconfig.template Config/BetaSecrets.local.xcconfig
$EDITOR Config/BetaSecrets.local.xcconfig

# 2. Generate the .xcodeproj
xcodegen generate
```

`Config/BetaSecrets.local.xcconfig` is in `.gitignore` — your keys never leave your machine. `Config/BetaSecrets.xcconfig` (committed) holds empty defaults; the `.local` variant overrides via an optional `#include?` at the bottom of the parent file.

You can leave any value blank. Empty values fall back to the runtime user-entry flow:

| Variable | Empty → behavior |
|---|---|
| `PIDGY_TG_API_ID` / `PIDGY_TG_API_HASH` | AuthView shows the credential entry step on first launch |
| `PIDGY_BUNDLED_OPENAI_API_KEY` | Preferences → AI Settings prompts for a BYO key |

### Build & run

```bash
xcodebuild -project Pidgy.xcodeproj -scheme Pidgy -configuration Debug \
  -destination 'platform=macOS,arch=arm64' build

open ~/Library/Developer/Xcode/DerivedData/Pidgy-*/Build/Products/Debug/Pidgy.app
```

The post-build step stamps the current `git rev-parse --short HEAD` into the built `Info.plist` under `PidgyBuildCommitSHA`. You'll see it in **Preferences → About → Build**, which makes bug reports traceable to a specific commit.

### Run tests

```bash
xcodebuild -project Pidgy.xcodeproj -scheme Pidgy \
  -destination 'platform=macOS,arch=arm64' test
```

### Package a beta `.dmg`

```bash
# Ad-hoc signed (testers see Gatekeeper "unverified developer" once)
scripts/make_dmg.sh

# Signed with your Developer ID (no Gatekeeper warning)
scripts/make_dmg.sh --sign "Developer ID Application: Your Name (TEAMID)"

# Signed and notarized (the gold standard)
xcrun notarytool store-credentials pidgy-beta            # one-time, uses an app-specific password
scripts/make_dmg.sh --sign "Developer ID Application: Your Name (TEAMID)" --notarize
```

Output lands in `dist/Pidgy-<short-sha>.dmg` (gitignored). Send that file to your tester. The dmg name carries the commit so you can correlate any bug report back to the exact build.

## For beta testers

You should have received a `Pidgy-<sha>.dmg` file. To install:

1. Double-click the `.dmg` to mount it. A window opens with `Pidgy.app` and an `Applications` shortcut — drag the app onto the shortcut to install. Then eject the dmg (right-click the volume on your desktop → **Eject**).
2. The first launch may trigger macOS Gatekeeper. There are two flavors of warning:
   - **"Apple cannot verify Pidgy is free of malware"** — open System Settings → Privacy & Security → scroll to the bottom → click **Open Anyway** next to the Pidgy entry. (This appears for ad-hoc-signed beta builds; a notarized build won't show it.)
   - **"Pidgy is damaged and can't be opened"** — only happens if your Mac stripped the quarantine flag oddly. Run once: `xattr -dr com.apple.quarantine /Applications/Pidgy.app`.
3. The app lives in your menu bar (the bird icon). Open the dashboard from the menu bar item or with **⌘ ⇧ T**.
4. On first launch you'll either:
   - Sign into Telegram via QR code (recommended) or phone number, then start using the dashboard. **No api_id / api_hash entry required** — that's baked into the build for this beta cohort.
   - If signin fails because credentials are missing, contact the dev — that means the build wasn't packaged with the right values.

### What hits the network

| Endpoint | When | What gets sent |
|---|---|---|
| `api.telegram.org` (via TDLib) | Always, while signed in | Your Telegram session — sync chats and download message history |
| `api.openai.com/v1/chat/completions` | When AI features run (reply suggestions, task extraction, semantic search) and an OpenAI key is configured | Recent message snippets from the chat being analyzed + the prompt that drives that feature |
| `api.anthropic.com/v1/messages` | Same as above, if a Claude key is configured instead | Same |
| `*.ingest.us.sentry.io` (Sentry SDK) | If a Sentry DSN was bundled into the build — crashes only, plus the explicit `PidgyTelemetry.capture(error:)` non-fatal sites | Stack trace + device/OS metadata. Event bodies pass through `scrubEvent` (`Sources/App/PidgyTelemetry.swift`) before send, which strips raw Telegram message text, sender names, phone numbers, and API tokens. You can disable by building from source without `PIDGY_SENTRY_DSN` set |

**Telemetry honesty:**
- **No analytics SDK** (no Mixpanel / Amplitude / PostHog / Google Analytics) — no usage events, no session tracking, no funnels.
- **One crash-reporting SDK**: Sentry, opt-in via the bundled DSN above. PII-scrubbed, no message bodies.
- **No third-party LLM tracing — in any build.** The LangSmith tracer that previously shipped raw prompts to LangChain's servers in Debug builds has been removed entirely. Its replacement (`LocalAITraceRecorder.swift`) writes LLM call traces to a local file only (`~/Library/Application Support/Pidgy/traces/`, Debug builds only, wiped by "Reset all local data"); the type contains no networking code, so there is no configuration in which prompt or message content can leave the machine through it.
- **Failure shapes, not content.** When an AI call fails (parse error, HTTP error, transport error, planner fallback), a content-free event goes to Sentry: provider, model, request kind, and error class — never the prompt, the response, or any message text (`PidgyTelemetry.captureAIFailure`, throttled to one event per failure shape per 5 minutes). Full failure detail stays on-device in the local trace file.
- **"Flag answer" is preview-first.** The flag affordances (launcher AI answers, reply-queue triage via right-click, task rows via right-click) never send anything by themselves: it saves a fixture locally and opens the feedback sheet with the flagged context (your query + the shown answer) as a **visible, removable attachment** — the full payload is scrollable in the sheet, a Remove button drops it entirely, and the footer states exactly what will be sent. Your typed note travels with the attachment only if you keep it.

Open the **About** preferences page to see the exact commit you're running.

### Filing a bug

Include:
1. Your build commit SHA (Preferences → About → Build).
2. Steps to reproduce.
3. Anything Console.app shows under `subsystem == "com.pidgy.app"` if you can grab it.

### Reset

Preferences → **Reset all local data** wipes:
- All Telegram credentials and the local TDLib database
- All AI provider keys
- All UserDefaults (chip pins, includeBots, etc.)
- The entire `~/Library/Application Support/Pidgy/` directory

Bundled beta credentials are *not* persisted to your Keychain (so a key rotation in the next build will take effect cleanly).

## License

TBD.
