/*
 * Soft sound-design layer for the Pidgy launch video.
 *
 * The music bed is the pidgy.chat site track (public/golden-hour-haze.mp3).
 * This script renders only the small, quiet effects that sit underneath it:
 * key clicks, card pops, air swells on transitions, wing flutters and chimes.
 * Every hit comes from HITS in src/timeline.ts, so the sound stays locked to
 * the picture.
 *
 *   npx tsx scripts/synth.ts  ->  public/sfx.wav (48 kHz, 16-bit stereo)
 */
import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { DURATION, FPS, HITS, type Hit } from "../src/timeline";

const SR = 48000;
const LEN = Math.ceil((DURATION / FPS) * SR);
const L = new Float32Array(LEN);
const R = new Float32Array(LEN);
const send = new Float32Array(LEN);

const put = (i: number, v: number, pan = 0, rev = 0) => {
  if (i < 0 || i >= LEN) return;
  L[i] += v * Math.cos(((pan + 1) * Math.PI) / 4) * 1.414;
  R[i] += v * Math.sin(((pan + 1) * Math.PI) / 4) * 1.414;
  send[i] += v * rev;
};

let seed = 20260925;
const noise = () => {
  seed = (seed * 1664525 + 1013904223) >>> 0;
  return seed / 2147483648 - 1;
};
const sec = (t: number) => Math.round(t * SR);

class Biquad {
  b0 = 1; b1 = 0; b2 = 0; a1 = 0; a2 = 0; x1 = 0; x2 = 0; y1 = 0; y2 = 0;
  set(type: "lp" | "hp" | "bp", f: number, q = 0.707) {
    const w = (2 * Math.PI * Math.min(f, SR * 0.45)) / SR;
    const cs = Math.cos(w);
    const al = Math.sin(w) / (2 * q);
    const [b0, b1, b2] =
      type === "lp" ? [(1 - cs) / 2, 1 - cs, (1 - cs) / 2] : type === "hp" ? [(1 + cs) / 2, -(1 + cs), (1 + cs) / 2] : [al, 0, -al];
    const a0 = 1 + al;
    this.b0 = b0 / a0; this.b1 = b1 / a0; this.b2 = b2 / a0; this.a1 = (-2 * cs) / a0; this.a2 = (1 - al) / a0;
    return this;
  }
  run(x: number) {
    const y = this.b0 * x + this.b1 * this.x1 + this.b2 * this.x2 - this.a1 * this.y1 - this.a2 * this.y2;
    this.x2 = this.x1; this.x1 = x; this.y2 = this.y1; this.y1 = y;
    return y;
  }
}

// A major pentatonic: the bed is in A major (chroma analysis of the mp3).
const PENT = [880, 987.8, 1108.7, 1318.5, 1480];

const render = (h: Hit) => {
  const s0 = sec(h.f / FPS);
  const g = h.gain ?? 1;
  const pan = h.pan ?? 0;
  const p = h.pitch ?? 0;
  switch (h.kind) {
    case "key": {
      const bp = new Biquad().set("bp", 3000 + p * 500, 1.4);
      const lp = new Biquad().set("lp", 900, 0.7);
      for (let i = 0; i < sec(0.05); i++) {
        const t = i / SR;
        const n = noise();
        put(s0 + i, (bp.run(n) * Math.exp(-t / 0.004) + lp.run(n) * Math.exp(-t / 0.012) * 0.6) * 0.22 * g, (p - 1) * 0.15);
      }
      break;
    }
    case "click": {
      const hp = new Biquad().set("hp", 1800, 0.8);
      for (let i = 0; i < sec(0.04); i++) {
        const t = i / SR;
        const n = hp.run(noise());
        const body = Math.sin(2 * Math.PI * 1320 * t) * Math.exp(-t / 0.006);
        put(s0 + i, (n * Math.exp(-t / 0.003) * 0.7 + body * 0.5) * 0.2 * g, 0.1, 0.1);
      }
      break;
    }
    case "thock": {
      const lp = new Biquad().set("lp", 1400, 0.8);
      for (let i = 0; i < sec(0.12); i++) {
        const t = i / SR;
        const tone = Math.sin(2 * Math.PI * (180 + p * 20) * t) * Math.exp(-t / 0.03);
        put(s0 + i, (lp.run(noise()) * Math.exp(-t / 0.01) * 0.8 + tone * 0.6) * 0.35 * g, (p - 1) * 0.2, 0.1);
      }
      break;
    }
    case "pop": {
      const f = PENT[p % PENT.length] / 2;
      let ph = 0;
      for (let i = 0; i < sec(0.25); i++) {
        const t = i / SR;
        ph += (2 * Math.PI * f * (1 + 0.25 * Math.exp(-t / 0.015))) / SR;
        put(s0 + i, Math.sin(ph) * Math.exp(-t / 0.06) * 0.16 * g, (p % 3 - 1) * 0.2, 0.3);
      }
      break;
    }
    case "tick": {
      for (let i = 0; i < sec(0.2); i++) {
        const t = i / SR;
        put(s0 + i, Math.sin(2 * Math.PI * 1760 * t) * Math.exp(-t / 0.05) * 0.08 * g, 0, 0.4);
      }
      break;
    }
    case "air": {
      const dur = 0.9;
      const bp = new Biquad();
      for (let i = 0; i < sec(dur); i++) {
        const t = i / SR;
        const x = t / dur;
        if (i % 64 === 0) bp.set("bp", 400 + 1800 * Math.sin(x * Math.PI), 0.6);
        const e = Math.pow(Math.sin(x * Math.PI), 2);
        put(s0 + i, bp.run(noise()) * e * 0.22 * g, (x - 0.5) * 0.8, 0.2);
      }
      break;
    }
    case "wings": {
      const bp = new Biquad().set("bp", 900, 0.9);
      const dur = 1.6;
      for (let i = 0; i < sec(dur); i++) {
        const t = i / SR;
        const beat = Math.pow(Math.max(0, Math.sin(2 * Math.PI * 6.2 * t)), 3);
        const e = Math.sin((t / dur) * Math.PI);
        put(s0 + i, bp.run(noise()) * beat * e * 0.3 * g, pan + (t / dur) * 0.8, 0.15);
      }
      break;
    }
    case "chime": {
      const notes = p === 0 ? [0, 2, 4] : [0, 2, 3, 4];
      notes.forEach((n, k) => {
        const f = PENT[n];
        const o = sec(k * 0.09);
        for (let i = 0; i < sec(2.2); i++) {
          const t = i / SR;
          const v = (Math.sin(2 * Math.PI * f * t) + 0.25 * Math.sin(2 * Math.PI * f * 2.01 * t) * Math.exp(-t / 0.2)) * Math.exp(-t / 0.7);
          put(s0 + o + i, v * 0.07 * g, (k - 1.5) * 0.3, 0.5);
        }
      });
      break;
    }
  }
};
HITS.forEach(render);

// Small room reverb on the send.
{
  const combs = [1557, 1617, 1491, 1422, 1277, 1356];
  const aps = [556, 441, 341];
  for (const [ch, out] of [[0, L], [1, R]] as const) {
    const cb = combs.map((d) => new Float32Array(d + ch * 23));
    const ci = combs.map(() => 0);
    const cl = combs.map(() => 0);
    const ab = aps.map((d) => new Float32Array(d + ch * 23));
    const ai = aps.map(() => 0);
    for (let i = 0; i < LEN; i++) {
      const x = send[i] * 0.02;
      let y = 0;
      for (let c = 0; c < cb.length; c++) {
        const o = cb[c][ci[c]];
        cl[c] = o * 0.7 + cl[c] * 0.3;
        cb[c][ci[c]] = x + cl[c] * 0.8;
        ci[c] = (ci[c] + 1) % cb[c].length;
        y += o;
      }
      for (let a = 0; a < ab.length; a++) {
        const o = ab[a][ai[a]];
        ab[a][ai[a]] = y + o * 0.5;
        ai[a] = (ai[a] + 1) % ab[a].length;
        y = o - y;
      }
      out[i] += y;
    }
  }
}

let peak = 0;
for (let i = 0; i < LEN; i++) peak = Math.max(peak, Math.abs(L[i]), Math.abs(R[i]));
const norm = peak > 0.7 ? 0.7 / peak : 1;

const data = Buffer.alloc(LEN * 4);
for (let i = 0; i < LEN; i++) {
  data.writeInt16LE(Math.round(Math.max(-1, Math.min(1, L[i] * norm)) * 32767), i * 4);
  data.writeInt16LE(Math.round(Math.max(-1, Math.min(1, R[i] * norm)) * 32767), i * 4 + 2);
}
const header = Buffer.alloc(44);
header.write("RIFF", 0);
header.writeUInt32LE(36 + data.length, 4);
header.write("WAVEfmt ", 8);
header.writeUInt32LE(16, 16);
header.writeUInt16LE(1, 20);
header.writeUInt16LE(2, 22);
header.writeUInt32LE(SR, 24);
header.writeUInt32LE(SR * 4, 28);
header.writeUInt16LE(4, 32);
header.writeUInt16LE(16, 34);
header.write("data", 36);
header.writeUInt32LE(data.length, 40);

const dest = join(dirname(fileURLToPath(import.meta.url)), "..", "public", "sfx.wav");
writeFileSync(dest, Buffer.concat([header, data]));
console.log(`sfx.wav: ${HITS.length} hits, peak ${peak.toFixed(3)}`);
