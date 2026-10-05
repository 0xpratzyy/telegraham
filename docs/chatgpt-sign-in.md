# ChatGPT plan connection

Pidgy uses OpenAI's locally hosted, open-source token-sharing flow. Eligibility,
limits, and model access are controlled by OpenAI. Remotely hosted or commercial
products require their own approved integration; do not reuse this configuration
as a generic commercial client.

The optional AI connection appears in onboarding’s AI stage (after sources) and Preferences → AI. Sources and AI may be deferred independently. It is
separate from Clerk/Pidgy identity and does not import ChatGPT conversations.
Use **Continue with ChatGPT**, finish the browser authorization, then choose a
model. Multiple account/workspace registrations are stored separately.

## Protocol and storage

- First authorization uses `dynamic_agent_client`, `agent_name_hint=Pidgy`, and
  a stable per-install `urn:uuid:` host ID. Returning authorization uses the
  issued `oaiapp_…` ID for that account/workspace.
- Every attempt has fresh state, nonce, and S256 PKCE. The loopback listener
  binds IPv4 `127.0.0.1`, chooses an ephemeral port, and is ready before the
  browser opens. The exact `/auth/callback` URI is reused in token exchange.
- ID tokens require RSA signature verification against the official JWKS,
  issuer, audience, expiry, issuance time, nonce, and subject checks. An existing
  registration cannot silently change subject. Inference additionally requires
  `resource.invoke` and `chatgpt.tokens.use.direct`.
- Release stores the account vault in macOS Keychain. Debug uses the existing
  owner-only credential files. Never log token responses or callback codes.
- Refreshes serialize per registration and save rotating tokens together.
  Temporary failures preserve credentials. Terminal invalid-grant failures
  clear credentials and require sign-in. Sign-out attempts discovered remote
  revocation, then clears local tokens and keeps the client mapping.
- Models come from the account's `/v1/models` catalog. Only visible entries
  are selectable. There is no inference probe on application startup.
- Inference uses public `/v1/responses`, `store: false`, `stream: true`, an
  `instructions` string, and a user input array. An interrupted, failed, or
  incomplete SSE stream never returns a partial answer as success.

## Usage and recovery

Background fact extraction is off until explicitly enabled. The launcher
shows **Using ChatGPT plan** and **Manage usage** while selected. Limits do
not silently fall back to cash-billed Gemini/OpenAI/Jev. Token counters are
recorded as unpriced plan requests, not invented dollar estimates.

If plan scope was not granted, sign in again with consent. If a refresh token
is invalid, sign in again. If model access or plan limits fail, use Manage
usage, wait for a reset, or explicitly choose a different provider. If remote
sign-out could not be confirmed, disconnect Pidgy in ChatGPT settings. Reset
all local data clears local tokens; it does not guarantee remote revocation.

## Verification

`Tests/ChatGPTTests.swift` checks dynamic registration, PKCE/state, callback
handling, JWT signatures and claim failures, refresh concurrency and rotation,
permission loss, sign-out, Responses request shape, and SSE failure handling.
All use synthetic data and do not consume ChatGPT allowance. A real browser
sign-in and completed Responses request still require an eligible account and
user consent; mock tests are not evidence of live provider approval.

Official sources: [open-source flow](https://developers.openai.com/siwc/token-sharing-open-source),
[sign-in](https://developers.openai.com/siwc/token-sharing-open-source/sign-in),
[models and inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference),
[session lifecycle](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions).
