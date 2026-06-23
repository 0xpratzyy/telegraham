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

export default {
  async fetch(request, env, ctx) {
    if (request.method !== "POST") {
      return json(405, { error: "method_not_allowed" });
    }
    const url = new URL(request.url);
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

// --- Vertex / Google OAuth: mint an access token from the SA key ----------
// In-isolate cache: Workers reuse isolates, so most requests reuse a token;
// a cold isolate mints once. No persistence — the token never touches KV.
let cachedToken = null; // { token: string, exp: number(epoch secs) }
let inflightToken = null; // Promise<string> while a mint is in progress

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
