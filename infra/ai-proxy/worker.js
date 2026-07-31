/**
 * Pidgy AI proxy — bare Cloudflare Worker, non-logging pass-through (issue #26).
 *
 * Purpose: the shipped .app must not bundle provider API keys (extractable
 * via `strings`). The app instead ships a revocable gate token and points its
 * provider here; this Worker holds the real credentials as Worker secrets and
 * forwards requests verbatim upstream.
 *
 * Two upstreams, selected by PATH (never by inspecting the body):
 *   /v1/chat/completions         -> OpenAI            (secret: OPENAI_API_KEY)
 *   /v1/vertex/chat/completions  -> Vertex AI Gemini  (secret: GCP_SA_KEY)
 * Vertex is reached through Google's OpenAI-compatible endpoint, so the body
 * format the app already sends works unchanged; the app just sets
 * `model: "google/gemini-3-flash-preview"`.
 *
 * PRIVACY CONSTRAINT (load-bearing — do not "improve" this away):
 * message content may TRANSIT this Worker in memory, but must never be
 * stored or logged on infrastructure we run. Concretely:
 *   - no console.log/console.error of request or response bodies
 *   - no KV/R2/D1/queue writes of bodies — KV holds day-bucket counters ONLY
 *   - no analytics engine, no tail consumers, no AI Gateway (it logs prompts
 *     by default, which is why this is a bare Worker)
 *   - request/response bodies are passed as streams and never parsed here
 * Keep Cloudflare dashboard "Workers Logs"/"Logpush" DISABLED for this Worker.
 *
 * Secrets (set via `wrangler secret put`, never in this file / wrangler.toml):
 *   OPENAI_API_KEY     — the real OpenAI key; never ships in the client
 *   GCP_SA_KEY         — full pidgy-vertex service-account JSON (one line)
 *   PIDGY_PROXY_TOKEN  — shared beta gate token the app presents as Bearer
 * Bindings / vars (wrangler.toml):
 *   RATE               — KV namespace for the daily request counter
 *   DAILY_REQUEST_CAP  — spend backstop, requests/day across the cohort
 */

const OPENAI_UPSTREAM = "https://api.openai.com/v1/chat/completions";
const OPENAI_PATH = "/v1/chat/completions";
const VERTEX_PATH = "/v1/vertex/chat/completions";
// Gemini 3 preview models live on the `global` location, not a region.
const VERTEX_LOCATION = "global";
const INVITE_PREFIX = "/v1/invite/";

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    // Invite/referral endpoints (issue: beta invite gate). Handled before
    // the AI pass-through; they never touch the AI daily cap and store
    // ONLY opaque identifiers (codes + random install ids) in KV — no
    // message content, no Telegram identity. The privacy constraint above
    // is untouched.
    if (url.pathname.startsWith(INVITE_PREFIX)) {
      return handleInvite(request, env, url);
    }
    if (request.method !== "POST") {
      return json(405, { error: "method_not_allowed" });
    }
    const isVertex = url.pathname === VERTEX_PATH;
    if (url.pathname !== OPENAI_PATH && !isVertex) {
      return json(404, { error: "not_found" });
    }

    // --- Gate token (timing-safe compare) ---
    const auth = request.headers.get("Authorization") ?? "";
    const presented = auth.startsWith("Bearer ") ? auth.slice(7) : "";
    if (!env.PIDGY_PROXY_TOKEN || !(await timingSafeEqual(presented, env.PIDGY_PROXY_TOKEN))) {
      return json(401, { error: "invalid_token" });
    }

    // --- Per-user license gate (managed/Vertex path only) ---
    // Ships DORMANT behind ENFORCE_LICENSE so deploying it changes nothing
    // until the cutover. When a license is presented we validate it against
    // Dodo's PUBLIC validate endpoint (no API key) and reject a lapsed/refunded
    // one — this is what stops a cancelled subscriber from continuing to spend
    // our managed AI budget. A request with NO license still passes the
    // shared-token gate above (trial + grandfathered users); tighten to require
    // a license once those cohorts are migrated. Fails OPEN on a Dodo outage so
    // a validate blip never locks out paying users (mirrors the client).
    if (isVertex && env.ENFORCE_LICENSE === "1") {
      const license = request.headers.get("X-Pidgy-License");
      if (license && !(await dodoLicenseValid(env, license))) {
        return json(402, { error: "license_invalid_or_lapsed" });
      }
    }

    // --- Daily request-count cap (counters only; never content) ---
    // Belt: this cap. Suspenders: the hard spend limits on the upstream
    // accounts (OpenAI dashboard cap; GCP budget alert on the Vertex project).
    const cap = Number(env.DAILY_REQUEST_CAP ?? "5000");
    const day = new Date().toISOString().slice(0, 10); // UTC YYYY-MM-DD
    const counterKey = `count:${day}`;
    const used = Number((await env.RATE.get(counterKey)) ?? "0");
    if (used >= cap) {
      return json(429, { error: "daily_cap_exceeded" });
    }
    // The increment happens AFTER we successfully dispatch upstream (below) —
    // failed token mints / unconfigured paths return early and must not burn
    // the shared cap, or one broken upstream would exhaust it and DoS every
    // beta client behind the same gate token.

    // --- Resolve upstream + auth header by path ---
    let upstreamUrl, upstreamAuth;
    if (isVertex) {
      if (!env.GCP_SA_KEY) return json(503, { error: "vertex_not_configured" });
      let sa, token;
      try {
        sa = JSON.parse(env.GCP_SA_KEY);
        token = await getVertexToken(sa);
      } catch (_) {
        // No body/content in the error — just signal the auth step failed.
        return json(502, { error: "vertex_auth_failed" });
      }
      upstreamUrl =
        `https://aiplatform.googleapis.com/v1beta1/projects/${sa.project_id}` +
        `/locations/${VERTEX_LOCATION}/endpoints/openapi/chat/completions`;
      upstreamAuth = `Bearer ${token}`;
    } else {
      upstreamUrl = OPENAI_UPSTREAM;
      upstreamAuth = `Bearer ${env.OPENAI_API_KEY}`;
    }

    // --- Forward verbatim; stream the response straight back ---
    // request.body is passed through as a stream and the upstream Response
    // object is returned as-is, so nothing is buffered or inspected here.
    const upstream = await fetch(upstreamUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: upstreamAuth,
      },
      body: request.body,
    });

    // Count the request now that it actually reached an upstream. Non-atomic
    // increment is fine: this is a coarse spend backstop, not a billing meter.
    // waitUntil keeps the KV write off the response's critical path;
    // expirationTtl stops stale day-buckets from accumulating forever.
    ctx.waitUntil(
      env.RATE.put(counterKey, String(used + 1), { expirationTtl: 172800 }),
    );

    return new Response(upstream.body, {
      status: upstream.status,
      headers: responseHeaders(upstream),
    });
  },
};

// --- Invite gate + referrals ----------------------------------------------
// Beta is invite-only: onboarding hard-gates on a code, every onboarded
// install gets personal codes to hand out, and each successful referral
// rewards the referrer with bonus codes + a counted referral (redeemed as
// free Pro months at billing cutover).
//
// INVITES KV data model (identifiers only — never content, never identity):
//   code:<CODE>        {createdBy: installId|"root", status: "active"|"redeemed",
//                       redeemedBy?, redeemedAt?, createdAt}
//   install:<ID>       {codes: [CODE...], invitedBy: CODE|null, referrals: n,
//                       onboardedAt}
//   invattempts:<day>:<ID>  redeem attempts (brute-force throttle)
// KV is eventually consistent — fine at beta scale; a rare double-redeem
// race costs one extra invite, not money.
const CODES_PER_INSTALL = 3;
const BONUS_CODES_PER_REFERRAL = 2;
const REDEEM_ATTEMPTS_PER_DAY = 10;
// No 0/O/1/I/L/U — codes get read aloud and retyped.
const CODE_ALPHABET = "23456789ABCDEFGHJKMNPQRSTVWXYZ";

async function handleInvite(request, env, url) {
  if (request.method !== "POST") return json(405, { error: "method_not_allowed" });
  if (!env.INVITES) return json(503, { error: "invites_not_configured" });

  const auth = request.headers.get("Authorization") ?? "";
  const presented = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  const route = url.pathname.slice(INVITE_PREFIX.length);

  // Admin mint uses its OWN secret (never shipped in the app); the app
  // routes use the same shared gate token as the AI paths.
  if (route === "mint") {
    if (!env.INVITE_ADMIN_TOKEN || !(await timingSafeEqual(presented, env.INVITE_ADMIN_TOKEN))) {
      return json(401, { error: "invalid_token" });
    }
    return inviteMint(request, env);
  }
  if (!env.PIDGY_PROXY_TOKEN || !(await timingSafeEqual(presented, env.PIDGY_PROXY_TOKEN))) {
    return json(401, { error: "invalid_token" });
  }

  let body;
  try {
    body = await request.json();
  } catch (_) {
    return json(400, { error: "bad_json" });
  }
  const installId = typeof body.installId === "string" ? body.installId.slice(0, 64) : "";
  if (!installId) return json(400, { error: "missing_install_id" });

  if (route === "redeem") return inviteRedeem(env, body, installId);
  if (route === "status") return inviteStatus(env, installId);
  return json(404, { error: "not_found" });
}

async function inviteRedeem(env, body, installId) {
  // Re-onboard after a reset (same install id): idempotent — hand back the
  // existing registration instead of burning a second code.
  const existing = await env.INVITES.get(`install:${installId}`, "json");
  if (existing) {
    return json(200, { ok: true, codes: existing.codes, referrals: existing.referrals ?? 0, alreadyRegistered: true });
  }

  // Brute-force throttle per install per UTC day.
  const day = new Date().toISOString().slice(0, 10);
  const attemptsKey = `invattempts:${day}:${installId}`;
  const attempts = Number((await env.INVITES.get(attemptsKey)) ?? "0");
  if (attempts >= REDEEM_ATTEMPTS_PER_DAY) {
    return json(429, { error: "too_many_attempts" });
  }
  await env.INVITES.put(attemptsKey, String(attempts + 1), { expirationTtl: 172800 });

  const code = normalizeInviteCode(typeof body.code === "string" ? body.code : "");
  if (!code) return json(400, { error: "invalid_code" });
  const record = await env.INVITES.get(`code:${code}`, "json");
  if (!record) return json(404, { error: "invalid_code" });
  if (record.status === "redeemed") return json(409, { error: "code_already_used" });

  const now = new Date().toISOString();
  record.status = "redeemed";
  record.redeemedBy = installId;
  record.redeemedAt = now;
  await env.INVITES.put(`code:${code}`, JSON.stringify(record));

  const codes = await mintCodes(env, CODES_PER_INSTALL, installId);
  await env.INVITES.put(
    `install:${installId}`,
    JSON.stringify({ codes, invitedBy: code, referrals: 0, onboardedAt: now }),
  );

  // Reward the referrer: +1 counted referral (free Pro months at billing
  // cutover) and bonus codes to keep handing out.
  if (record.createdBy && record.createdBy !== "root") {
    const referrer = await env.INVITES.get(`install:${record.createdBy}`, "json");
    if (referrer) {
      const bonus = await mintCodes(env, BONUS_CODES_PER_REFERRAL, record.createdBy);
      referrer.codes = [...(referrer.codes ?? []), ...bonus];
      referrer.referrals = (referrer.referrals ?? 0) + 1;
      await env.INVITES.put(`install:${record.createdBy}`, JSON.stringify(referrer));
    }
  }

  return json(200, { ok: true, codes, referrals: 0 });
}

async function inviteStatus(env, installId) {
  const record = await env.INVITES.get(`install:${installId}`, "json");
  if (!record) return json(200, { registered: false });
  // Resolve per-code redemption so the app can show used/unused.
  const codes = await Promise.all(
    (record.codes ?? []).map(async (c) => {
      const entry = await env.INVITES.get(`code:${c}`, "json");
      return { code: c, redeemed: entry?.status === "redeemed" };
    }),
  );
  return json(200, { registered: true, codes, referrals: record.referrals ?? 0 });
}

async function inviteMint(request, env) {
  let body = {};
  try {
    body = await request.json();
  } catch (_) { /* default */ }
  const count = Math.min(Math.max(Number(body.count) || 1, 1), 50);
  const codes = await mintCodes(env, count, "root");
  return json(200, { ok: true, codes });
}

async function mintCodes(env, count, createdBy) {
  const now = new Date().toISOString();
  const codes = [];
  for (let i = 0; i < count; i++) {
    // Collision retry: 30^6 ≈ 729M combinations, so collisions are
    // vanishingly rare — the loop is a formality.
    for (let attempt = 0; attempt < 5; attempt++) {
      const code = generateInviteCode();
      if (await env.INVITES.get(`code:${code}`)) continue;
      await env.INVITES.put(
        `code:${code}`,
        JSON.stringify({ createdBy, status: "active", createdAt: now }),
      );
      codes.push(code);
      break;
    }
  }
  return codes;
}

function generateInviteCode() {
  const bytes = new Uint8Array(6);
  crypto.getRandomValues(bytes);
  let suffix = "";
  for (const b of bytes) suffix += CODE_ALPHABET[b % CODE_ALPHABET.length];
  return `PIDGY-${suffix}`;
}

/** Uppercase, strip everything but the alphabet, re-prefix. Accepts
 *  "pidgy-abc 123", "ABC123", "PIDGY-ABC123" → "PIDGY-ABC123". */
function normalizeInviteCode(raw) {
  const stripped = raw.toUpperCase().replace(/^PIDGY/, "").replace(/[^0-9A-Z]/g, "");
  if (stripped.length !== 6) return null;
  return `PIDGY-${stripped}`;
}

// --- Vertex / Google OAuth: mint an access token from the SA key ----------
// In-isolate cache: Workers reuse isolates, so most requests reuse a token;
// a cold isolate mints once. No persistence — the token never touches KV.
let cachedToken = null; // { token: string, exp: number(epoch secs) }
let inflightToken = null; // Promise<string> while a mint is in progress

// --- Dodo license validation (PUBLIC endpoint, no API key) -----------------
// false ONLY on an explicit invalid (4xx / valid:false). Fails OPEN on a
// network error or 5xx so a Dodo outage never locks out a paying user — the
// same network-vs-invalid distinction the client makes.
async function dodoLicenseValid(env, licenseKey) {
  const base = env.DODO_BASE_URL || "https://test.dodopayments.com";
  let resp;
  try {
    resp = await fetch(`${base}/licenses/validate`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ license_key: licenseKey }),
    });
  } catch (_) {
    return true; // couldn't reach Dodo → fail open
  }
  if (resp.status >= 500) return true; // server blip → fail open
  if (!resp.ok) return false; // 4xx → genuinely invalid
  try {
    const data = await resp.json();
    return data.valid === true;
  } catch (_) {
    return true; // unparseable → fail open
  }
}

async function getVertexToken(sa) {
  const now = Math.floor(Date.now() / 1000);
  if (cachedToken && cachedToken.exp - 60 > now) return cachedToken.token;
  // Coalesce concurrent cold-isolate mints: if one is already in flight, await
  // it rather than minting a second token in parallel for the same isolate.
  if (inflightToken) return inflightToken;

  inflightToken = (async () => {
    try {
      const tokenUri = sa.token_uri || "https://oauth2.googleapis.com/token";
      const header = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
      const claim = b64url(JSON.stringify({
        iss: sa.client_email,
        scope: "https://www.googleapis.com/auth/cloud-platform",
        aud: tokenUri,
        iat: now,
        exp: now + 3600,
      }));
      const signingInput = `${header}.${claim}`;
      const key = await importPkcs8(sa.private_key);
      const sigBuf = await crypto.subtle.sign(
        { name: "RSASSA-PKCS1-v1_5" }, key, new TextEncoder().encode(signingInput),
      );
      const jwt = `${signingInput}.${b64urlBytes(new Uint8Array(sigBuf))}`;

      const resp = await fetch(tokenUri, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body:
          "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer" +
          `&assertion=${jwt}`,
      });
      const data = await resp.json();
      if (!data.access_token) throw new Error("token_mint_failed");
      cachedToken = { token: data.access_token, exp: now + (data.expires_in || 3600) };
      return cachedToken.token;
    } finally {
      // Clear on both success and failure so a failed mint doesn't wedge all
      // future requests — the next call re-mints.
      inflightToken = null;
    }
  })();

  return inflightToken;
}

async function importPkcs8(pem) {
  const body = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey(
    "pkcs8", der.buffer,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false, ["sign"],
  );
}

function b64url(str) {
  return btoa(str).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function b64urlBytes(bytes) {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Copy safe upstream headers; drop hop-by-hop and provider org metadata. */
function responseHeaders(upstream) {
  const headers = new Headers();
  for (const name of ["content-type", "x-request-id", "openai-processing-ms"]) {
    const value = upstream.headers.get(name);
    if (value) headers.set(name, value);
  }
  return headers;
}

function json(status, payload) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "content-type": "application/json" },
  });
}

/** Constant-time string compare via crypto.subtle.timingSafeEqual. */
async function timingSafeEqual(a, b) {
  const encoder = new TextEncoder();
  // Hash both sides to fixed length first — timingSafeEqual requires equal
  // byte lengths, and hashing avoids leaking length information.
  const [da, db] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(a)),
    crypto.subtle.digest("SHA-256", encoder.encode(b)),
  ]);
  return crypto.subtle.timingSafeEqual(da, db);
}
