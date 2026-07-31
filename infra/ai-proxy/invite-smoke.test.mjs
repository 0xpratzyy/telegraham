// Smoke test for the invite routes with a mock KV.
// Run: cd infra/ai-proxy && node invite-smoke.test.mjs (needs node >= 20).
import worker from "./worker.js";

// Cloudflare-only API — shim for node.
if (!crypto.subtle.timingSafeEqual) {
  crypto.subtle.timingSafeEqual = (a, b) => {
    const va = new Uint8Array(a), vb = new Uint8Array(b);
    if (va.length !== vb.length) return false;
    let diff = 0;
    for (let i = 0; i < va.length; i++) diff |= va[i] ^ vb[i];
    return diff === 0;
  };
}

class MockKV {
  constructor() { this.map = new Map(); }
  async get(key, type) {
    const v = this.map.get(key) ?? null;
    if (v !== null && type === "json") return JSON.parse(v);
    return v;
  }
  async put(key, value) { this.map.set(key, value); }
}

const env = {
  INVITES: new MockKV(),
  PIDGY_PROXY_TOKEN: "app-token",
  INVITE_ADMIN_TOKEN: "admin-token",
};
const ctx = { waitUntil() {} };

const call = async (path, token, body) => {
  const resp = await worker.fetch(
    new Request(`https://x.example${path}`, {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify(body),
    }),
    env,
    ctx,
  );
  return { status: resp.status, body: await resp.json() };
};

const assert = (cond, label) => {
  if (!cond) { console.error(`FAIL: ${label}`); process.exit(1); }
  console.log(`ok: ${label}`);
};

// 1. Admin mints root codes; app token must NOT be able to mint.
const forbidden = await call("/v1/invite/mint", "app-token", { count: 2 });
assert(forbidden.status === 401, "mint rejects app token");
const mint = await call("/v1/invite/mint", "admin-token", { count: 2 });
assert(mint.status === 200 && mint.body.codes.length === 2, "admin mints 2 root codes");
const rootCode = mint.body.codes[0];
assert(/^PIDGY-[23456789ABCDEFGHJKMNPQRSTVWXYZ]{6}$/.test(rootCode), "code format");

// 2. Bad/unknown codes.
const badTok = await call("/v1/invite/redeem", "wrong", { installId: "A", code: rootCode });
assert(badTok.status === 401, "redeem rejects bad token");
const unknown = await call("/v1/invite/redeem", "app-token", { installId: "A", code: "PIDGY-999999" });
assert(unknown.status === 404, "unknown code 404");
const malformed = await call("/v1/invite/redeem", "app-token", { installId: "A", code: "xx" });
assert(malformed.status === 400, "malformed code 400");

// 3. Happy path: A redeems root code (messy formatting accepted), gets 3 codes.
const messy = rootCode.replace("PIDGY-", "pidgy - ").toLowerCase();
const redeemA = await call("/v1/invite/redeem", "app-token", { installId: "A", code: messy });
assert(redeemA.status === 200 && redeemA.body.codes.length === 3, "A onboards with 3 codes");

// 4. Double-spend of the same code fails.
const reuse = await call("/v1/invite/redeem", "app-token", { installId: "B", code: rootCode });
assert(reuse.status === 409, "reused code 409");

// 5. Same install re-redeems (post-reset) → idempotent, same codes, no burn.
const again = await call("/v1/invite/redeem", "app-token", { installId: "A", code: "PIDGY-999999" });
assert(again.status === 200 && again.body.alreadyRegistered === true
  && JSON.stringify(again.body.codes) === JSON.stringify(redeemA.body.codes),
  "re-onboard is idempotent");

// 6. Referral: B redeems one of A's codes → A gets +1 referral and +2 bonus codes.
const shared = redeemA.body.codes[0];
const redeemB = await call("/v1/invite/redeem", "app-token", { installId: "B", code: shared });
assert(redeemB.status === 200 && redeemB.body.codes.length === 3, "B onboards via A's code");
const statusA = await call("/v1/invite/status", "app-token", { installId: "A" });
assert(statusA.body.referrals === 1, "A credited 1 referral");
assert(statusA.body.codes.length === 5, "A has 3 + 2 bonus codes");
assert(statusA.body.codes.find((c) => c.code === shared).redeemed === true, "shared code shows redeemed");

// 7. Unknown install status.
const statusZ = await call("/v1/invite/status", "app-token", { installId: "Z" });
assert(statusZ.status === 200 && statusZ.body.registered === false, "unknown install unregistered");

// 8. Attempt throttle: 10 bad tries → 429 (fresh install id C).
let last;
for (let i = 0; i < 11; i++) {
  last = await call("/v1/invite/redeem", "app-token", { installId: "C", code: "PIDGY-999999" });
}
assert(last.status === 429, "brute-force throttle kicks in");

console.log("ALL PASS");
