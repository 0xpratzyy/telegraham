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

## For beta testers

You should have received a `.app` bundle in a `.zip`. To install:

1. Move `Pidgy.app` into `/Applications`.
2. The first time you launch, macOS Gatekeeper may say *"Pidgy" cannot be opened because the developer cannot be verified.* Right-click the app → **Open** → confirm. (This is because the build is signed with an ad-hoc identity for the cohort, not a Developer ID — a notarized build will land before public release.)
3. The app lives in your menu bar (the bird icon). Open the dashboard from the menu bar item or with **⌘ ⇧ T**.
4. On first launch you'll either:
   - Sign into Telegram via QR code (recommended) or phone number, then start using the dashboard. **No api_id / api_hash entry required** — that's baked into the build for this beta cohort.
   - If signin fails because credentials are missing, contact the dev — that means the build wasn't packaged with the right values.

### What hits the network

Pidgy talks to three places. Everything else stays on your Mac.

| Endpoint | Why |
|---|---|
| `api.telegram.org` (via TDLib) | Sync your chats and download message history |
| `api.openai.com/v1/chat/completions` | Reply suggestions, task extraction, semantic search (only when those features run) |
| `api.anthropic.com/v1/messages` | Same, if you've configured a Claude key instead |

No analytics, no telemetry, no third-party SDKs. Open the **About** preferences page to see the exact commit you're running.

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
