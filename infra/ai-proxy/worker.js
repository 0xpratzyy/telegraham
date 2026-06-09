/**
 * Pidgy AI proxy — bare Cloudflare Worker, non-logging pass-through (issue #26).
 *
 * Purpose: the shipped .app must not bundle the OpenAI API key (extractable
 * via `strings`). The app instead ships a revocable gate token and points
 * OpenAIProvider here; this Worker holds the real key as a Worker secret and
 * forwards requests verbatim to OpenAI.
 *
 * PRIVACY CONSTRAINT (load-bearing — do not "improve" this away):
 * message content may TRANSIT this Worker in memory, but must never be
 * stored or logged on infrastructure we run. Concretely:
 *   - no console.log/console.error of request or response bodies
 *   - no KV/R2/D1/queue writes of bodies — KV holds day-bucket counters ONLY
 *   - no analytics engine, no tail consumers, no AI Gateway (it logs prompts
 *     by default, which is why this is a bare Worker)
 * Keep Cloudflare dashboard "Workers Logs"/"Logpush" DISABLED for this
 * Worker; the README's deploy checklist covers that.
 *
 * Secrets (set via `wrangler secret put`, never in this file / wrangler.toml):
 *   OPENAI_API_KEY     — the real key; never ships in the client
 *   PIDGY_PROXY_TOKEN  — shared beta gate token the app presents as Bearer
 * Bindings / vars (wrangler.toml):
 *   RATE               — KV namespace for the daily request counter
 *   DAILY_REQUEST_CAP  — spend backstop, requests/day across the cohort
 */

const OPENAI_UPSTREAM = "https://api.openai.com/v1/chat/completions";
const ALLOWED_PATH = "/v1/chat/completions";

export default {
  async fetch(request, env) {
    if (request.method !== "POST") {
      return json(405, { error: "method_not_allowed" });
    }
    const url = new URL(request.url);
    if (url.pathname !== ALLOWED_PATH) {
      return json(404, { error: "not_found" });
    }

    // --- Gate token (timing-safe compare) ---
    const auth = request.headers.get("Authorization") ?? "";
    const presented = auth.startsWith("Bearer ") ? auth.slice(7) : "";
    if (!env.PIDGY_PROXY_TOKEN || !(await timingSafeEqual(presented, env.PIDGY_PROXY_TOKEN))) {
      return json(401, { error: "invalid_token" });
    }

    // --- Daily request-count cap (counters only; never content) ---
    // Belt: this cap. Suspenders: the hard monthly spend limit set on the
    // OpenAI key in the OpenAI dashboard.
    const cap = Number(env.DAILY_REQUEST_CAP ?? "5000");
    const day = new Date().toISOString().slice(0, 10); // UTC YYYY-MM-DD
    const counterKey = `count:${day}`;
    const used = Number((await env.RATE.get(counterKey)) ?? "0");
    if (used >= cap) {
      return json(429, { error: "daily_cap_exceeded" });
    }
    // Non-atomic increment is fine here: this is a coarse spend backstop,
    // not a billing meter. Worst case a burst overshoots by a few requests.
    // expirationTtl keeps stale day-buckets from accumulating forever.
    await env.RATE.put(counterKey, String(used + 1), { expirationTtl: 172800 });

    // --- Forward verbatim; stream the response straight back ---
    // request.body is passed through as a stream and the upstream Response
    // object is returned as-is, so nothing is buffered or inspected here.
    const upstream = await fetch(OPENAI_UPSTREAM, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${env.OPENAI_API_KEY}`,
      },
      body: request.body,
    });
    return new Response(upstream.body, {
      status: upstream.status,
      headers: responseHeaders(upstream),
    });
  },
};

/** Copy safe upstream headers; drop hop-by-hop and OpenAI org metadata. */
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
