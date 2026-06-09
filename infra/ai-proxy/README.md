# Pidgy AI proxy (issue #26)

A bare Cloudflare Worker that lets beta builds ship **without** the OpenAI API
key in the bundle. The app presents a revocable **gate token**; the Worker
holds the real key as a secret and forwards `POST /v1/chat/completions`
verbatim to OpenAI.

```
Pidgy.app ──Bearer <gate token>──▶ Worker ──Bearer <OPENAI_API_KEY>──▶ api.openai.com
              (extractable but        (key never ships;
               revocable, worthless    bodies transit in memory,
               outside this proxy)     never stored or logged)
```

## Privacy contract (why this is a *bare* Worker)

Message content may **transit** the Worker but must never be **stored or
logged** on infrastructure we run. That rules out Cloudflare AI Gateway
(logs prompts by default). The Worker itself never logs bodies and writes
only day-bucket request **counters** to KV. Two dashboard checkboxes are part
of the contract — after deploy, on the Worker's **Settings → Observability**:

- [ ] Workers Logs: **disabled**
- [ ] Logpush: **disabled**

## Deploy (one-time, ~10 min)

```bash
cd infra/ai-proxy
npm i -g wrangler        # or use npx wrangler
wrangler login

# 1. KV namespace for the daily counter
wrangler kv namespace create RATE
#    → paste the printed id into wrangler.toml ([[kv_namespaces]] id)

# 2. Secrets (never in git, never in wrangler.toml)
wrangler secret put OPENAI_API_KEY     # the real key
openssl rand -hex 32                   # generate the gate token, then:
wrangler secret put PIDGY_PROXY_TOKEN  # paste the generated token

# 3. Ship it
wrangler deploy
#    → note the URL, e.g. https://pidgy-ai-proxy.<account>.workers.dev
```

### Spend backstop (belt + suspenders)

- **Belt** — `DAILY_REQUEST_CAP` in `wrangler.toml` (requests/day across the
  cohort; 429 once exceeded).
- **Suspenders** — set a **hard monthly spend limit** on the key at
  <https://platform.openai.com/account/limits>. Do this even with the cap.

### Smoke test

```bash
PROXY=https://pidgy-ai-proxy.<account>.workers.dev
TOKEN=<the gate token>

# happy path → HTTP 200 with a model reply
curl -s "$PROXY/v1/chat/completions" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"model":"gpt-5.4-mini","messages":[{"role":"user","content":"Reply with OK"}]}' | head -c 300

# bad token → {"error":"invalid_token"} (401)
curl -s "$PROXY/v1/chat/completions" -H "Authorization: Bearer nope" -d '{}'
```

## Point the app at it

In `Config/BetaSecrets.local.xcconfig` (gitignored):

```
// '/' must be escaped in xcconfig values: https:/$()/host/path
PIDGY_AI_PROXY_URL = https:/$()/pidgy-ai-proxy.<account>.workers.dev/v1/chat/completions
PIDGY_AI_PROXY_TOKEN = <the gate token>
```

Then `xcodegen generate` and rebuild. Behavior matrix:

| Build state | AI requests go |
|---|---|
| Proxy URL+token bundled, no BYO key | → Worker (gate token; zero-setup UX preserved) |
| BYO key entered in AI Settings | → api.openai.com directly (their key, their bill) |
| Neither | AI Settings prompts for a key (unchanged) |

## Cutover: removing the bundled key from Release

Once the proxy is deployed and a proxied build is verified, blank the raw key
out of Release builds in `Config/BetaSecrets.local.xcconfig`:

```
PIDGY_BUNDLED_OPENAI_API_KEY[config=Debug] = sk-...   // keep for dev loops
PIDGY_BUNDLED_OPENAI_API_KEY[config=Release] =        // never ships again
```

(Same split LangSmith already uses. `Config/BetaSecrets.xcconfig` documents
this next to the variable.) Then rotate the previously-shipped OpenAI key at
platform.openai.com — every existing beta build carried it.

## Rotation / revocation

- **Gate token leaked or cohort changes:** `wrangler secret put
  PIDGY_PROXY_TOKEN` with a fresh value, update `BetaSecrets.local.xcconfig`,
  ship a new build. Old builds get 401 → AI Settings asks for a BYO key.
- **OpenAI key:** rotate at platform.openai.com, `wrangler secret put
  OPENAI_API_KEY`. No app rebuild needed.

## Threat model, honestly

The gate token ships in the bundle and is just as extractable as the key was.
The difference: it is **worthless outside this proxy** (which caps volume and
fronts a spend-limited key) and **revocable without burning the OpenAI key**.
This is the v1 trade the issue accepts; per-install tokens + per-user budgets
are the documented harden-later step.
