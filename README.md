# Pidgy

Local-first command center for Telegram, Slack, WhatsApp, and Gmail. Find conversations, track replies and tasks, and ask questions about your messages. Native macOS and SwiftUI.

How it works in one line: messages sync into a local SQLite store, an AI pass extracts durable **facts** (open loops, summaries) from them, and every surface — the reply queue, the Tasks page, and the "Ask Pidgy" answer chat — is a view over that one fact store. Details in [docs/architecture.md](docs/architecture.md).

## For developers — building from source

### Prerequisites

- macOS 26+, Xcode 26+ (validated with Xcode 27)
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- Go 1.25+, Python 3.10+, and Node.js 20+ for the WhatsApp bridge and checks
- A Telegram api_id / api_hash from <https://my.telegram.org/apps> if connecting Telegram
- Optional AI: **Continue with ChatGPT** using an eligible ChatGPT plan, or your own provider API key. Source builds include no shared API key, managed proxy, telemetry DSN, or automatic update feed.

### One-time setup

```bash
# 1. Drop your beta credentials into a gitignored file. The .template lists
#    the exact variable names and where each value comes from.
cp Config/BetaSecrets.local.xcconfig.template Config/BetaSecrets.local.xcconfig
$EDITOR Config/BetaSecrets.local.xcconfig

# 2. Generate the .xcodeproj
xcodegen generate
```

`Config/BetaSecrets.local.xcconfig` is in `.gitignore` — your local configuration stays out of Git. `Config/BetaSecrets.xcconfig` (committed) holds empty defaults; the `.local` variant overrides via an optional `#include?` at the bottom of the parent file.

You can leave any value blank. Empty values fall back to the runtime user-entry flow:

| Variable | Empty → behavior |
|---|---|
| `PIDGY_TG_API_ID` / `PIDGY_TG_API_HASH` | AuthView shows the credential entry step on first launch |
| `PIDGY_BUNDLED_OPENAI_API_KEY` | Preferences → AI Settings prompts for a BYO key |

### Build & run

```bash
PIDGY_SOURCE_BUILD=1 ./script/build_and_run.sh run
```

Use the repository launcher instead of `open -a Pidgy` or a DerivedData glob.
macOS LaunchServices can otherwise select a stale debug bundle from another
worktree because every local build shares the same bundle identifier.

The post-build step stamps the current commit into `Contents/Resources/PidgyBuildSHA.txt`. Source archives without Git history show `unknown`. You'll see it in **Preferences → About → Build**, which makes bug reports traceable to a specific commit.

### Run tests

```bash
./scripts/test.sh
```

### Continue with ChatGPT

In onboarding or **Preferences → AI**, choose **Continue with ChatGPT**. A system browser opens the official authorization page. After you grant access, select a model from the account's returned catalog. No OpenAI API key or OAuth client secret is needed. `PIDGY_SOURCE_BUILD=1` enables this local OSS flow; maintainer/commercial builds leave `PIDGY_CHATGPT_OSS_ENABLED=NO` until separately approved. This AI connection is separate from the optional Pidgy account used for invites and billing; it does not import your ChatGPT chats.

Requests consume your ChatGPT plan allowance or credits; they are not unlimited or priced as API-key requests. **Manage usage** opens ChatGPT's usage settings. Background fact extraction starts off and requires an explicit toggle. Limit failures are shown without switching to a separately billed provider. Model availability and eligibility are controlled by OpenAI. See the [integration guide](docs/chatgpt-sign-in.md) and [official open-source documentation](https://developers.openai.com/siwc/token-sharing-open-source).

### Prepare a public source snapshot

```bash
python3 scripts/prepare_open_source.py
```

This exports the current source, synthetic offline fixtures, dependency locks, and notices to `Build/OpenSourceAudit/source-*.tar.gz`, with a SHA-256 manifest. It excludes credentials, databases, binaries, chat-derived reports, personal marketing media, and the private Git history. Publish the snapshot in a **fresh repository**. Making this existing checkout public would expose historical chat fixtures and any historical credentials; the export does not sanitize Git history. Pattern scanning does not replace a final review of included files.

Source builds must keep `PIDGY_UPDATE_FEED_URL` blank unless you operate your own signed release feed. Maintainer beta packaging below is a separate distribution workflow. The WhatsApp helper and its corresponding source/dependency notices must accompany releases.

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
4. Setup has three stages: connect a source, choose optional AI, then try **⌘ ⇧ T** and decide whether Pidgy should start at login. Telegram, Slack, Gmail and WhatsApp are shown; availability depends on this build's configuration. Sources and AI can be set up later in Preferences. Connecting a source keeps setup open so you can add another.


### What hits the network

| Endpoint | When | What gets sent |
|---|---|---|
| Telegram data centers (via TDLib) | Always, while signed in | Your Telegram session — sync chats and download message history |
| `auth.openai.com`, `api.openai.com/v1/models`, `api.openai.com/v1/responses` | Only when you connect or use ChatGPT plan AI | OAuth registration/tokens for sign-in; selected message context and prompts for inference. Tokens stay local; Responses uses `store: false`. ChatGPT conversations are not imported |
| Slack, Google/Gmail, WhatsApp service endpoints | When a source is connected | Source authorization, message sync, attachments, and connection state |
| `api.typesafe.ai` | If you explicitly enable the separate TypeSafe/Jev key | Text supplied for enabled classification and predictive features; this provider is disabled while ChatGPT plan AI is selected |
| `api.openai.com/v1/chat/completions` | When AI features run (fact extraction, Ask Pidgy answers, semantic search, summaries, reply suggestions) and an OpenAI key is configured | Recent message snippets from the chat being analyzed + the prompt that drives that feature |
| `api.anthropic.com/v1/messages` | Same as above, if a Claude key is configured instead | Same |
| Pidgy AI proxy (Cloudflare Worker) | Same as above, on the managed plan (no BYO key) | Same snippets — the proxy forwards to the model provider (Gemini via Vertex) and holds the provider key server-side |
| Pidgy AI proxy `/v1/invite/*`, `/v1/account/link` | Once at onboarding (invite-code redeem) and when you open Preferences → Invites | ONLY the invite code string + the random per-install id, plus — if you signed in — your Clerk session token so the account can be linked to this install. Never your Telegram account, never message content |
| `clerk.com` (Clerk SDK) | Only if you choose Continue with Google / Apple in onboarding or Preferences → Account | The OAuth sign-in itself (in a system browser sheet) and session refreshes. Clerk stores your email + name. Nothing about your chats. Skip sign-in and no request is made |
| `*.ingest.us.sentry.io` (Sentry SDK) | If a Sentry DSN was bundled into the build — crashes only, plus the explicit `PidgyTelemetry.capture(error:)` non-fatal sites | Stack trace + device/OS metadata. Event bodies pass through `scrubEvent` (`Sources/App/PidgyTelemetry.swift`) before send, which strips raw Telegram message text, sender names, phone numbers, and API tokens. You can disable by building from source without `PIDGY_SENTRY_DSN` set |

**Telemetry honesty:**
- **No analytics SDK** (no Mixpanel / Amplitude / PostHog / Google Analytics) — no usage events, no session tracking, no funnels.
- **One crash-reporting SDK**: Sentry, opt-in via the bundled DSN above. PII-scrubbed, no message bodies. Attaching your Telegram @username/name to crash reports is **opt-in** (Preferences → Diagnostics, default off) — by default events carry only a random per-install id. Debug-symbol (dSYM) uploads to Sentry happen only in the notarized release pipeline (`make_dmg.sh --notarize`), never as a side effect of a local build.
- **No third-party LLM tracing — in any build.** The LangSmith tracer that previously shipped raw prompts to LangChain's servers in Debug builds has been removed entirely. Its replacement (`LocalAITraceRecorder.swift`) writes LLM call traces to a local file only (`~/Library/Application Support/Pidgy/traces/`, Debug builds only, wiped by "Reset all local data"); the type contains no networking code, so there is no configuration in which prompt or message content can leave the machine through it.
- **On-device semantic search.** Embeddings run locally using Apple NaturalLanguage or SwiftEmbeddings. Model assets may download from Apple or Hugging Face; message content is not sent for embedding computation.
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
- All AI provider keys and locally saved ChatGPT tokens (disconnect the app in ChatGPT settings to revoke remote access after a reset)
- All UserDefaults (chip pins, includeBots, etc.)
- The entire `~/Library/Application Support/Pidgy/` directory

Bundled beta credentials are *not* persisted to your Keychain (so a key rotation in the next build will take effect cleanly).

## License

First-party Swift app and supporting code: [MIT](LICENSE). The separately built WhatsApp bridge is [GPL-3.0-or-later](tools/WhatsAppBridge/LICENSE), because it links GPL-licensed libsignal. Dependencies and fonts retain their licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Do not describe the entire distributed binary bundle as MIT-only.
