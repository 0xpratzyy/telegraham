/*
 * Procedural soundtrack for the Pidgy launch video.
 *
 * Pure Node, no audio dependencies: every drum, synth voice and sound effect
 * is generated sample by sample. The beat grid and the SFX hit list come from
 * src/timeline.ts, so the music is locked to the picture by construction.
 *
 *   npx tsx scripts/synth.ts  ->  public/soundtrack.wav (48 kHz, 16-bit stereo)
 */
import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { BPM, DURATION, FPS, HITS, SCENES, type Hit } from "../src/timeline";

const SR = 48000;
const LEN = Math.ceil((DURATION / FPS) * SR);
const SPB = 60 / BPM; // seconds per beat
const SBAR = SPB * 4;

// ---------------------------------------------------------------------------
// Buses
const mk = () => [new Float32Array(LEN), new Float32Array(LEN)] as const;
const drums = mk();
const music = mk();
const sfx = mk();
const verbSend = new Float32Array(LEN);

type Bus = readonly [Float32Array, Float32Array];

const put = (bus: Bus, i: number, v: number, pan = 0, send = 0) => {
  if (i < 0 || i >= LEN) return;
  const l = Math.cos(((pan + 1) * Math.PI) / 4);
  const r = Math.sin(((pan + 1) * Math.PI) / 4);
  bus[0][i] += v * l * 1.414;
  bus[1][i] += v * r * 1.414;
  if (send) verbSend[i] += v * send;
};

// Deterministic noise.
let seed = 1234567;
const noise = () => {
  seed = (seed * 1664525 + 1013904223) >>> 0;
  return seed / 2147483648 - 1;
};

const mtof = (m: number) => 440 * Math.pow(2, (m - 69) / 12);
const sec = (t: number) => Math.round(t * SR);

// RBJ biquad.
class Biquad {
  b0 = 1; b1 = 0; b2 = 0; a1 = 0; a2 = 0;
  x1 = 0; x2 = 0; y1 = 0; y2 = 0;
  set(type: "lp" | "hp" | "bp", f: number, q = 0.707) {
    const w = (2 * Math.PI * Math.min(f, SR * 0.45)) / SR;
    const cs = Math.cos(w);
    const al = Math.sin(w) / (2 * q);
    let b0: number, b1: number, b2: number;
    if (type === "lp") { b0 = (1 - cs) / 2; b1 = 1 - cs; b2 = (1 - cs) / 2; }
    else if (type === "hp") { b0 = (1 + cs) / 2; b1 = -(1 + cs); b2 = (1 + cs) / 2; }
    else { b0 = al; b1 = 0; b2 = -al; }
    const a0 = 1 + al;
    this.b0 = b0 / a0; this.b1 = b1 / a0; this.b2 = b2 / a0;
    this.a1 = (-2 * cs) / a0; this.a2 = (1 - al) / a0;
    return this;
  }
  run(x: number) {
    const y = this.b0 * x + this.b1 * this.x1 + this.b2 * this.x2 - this.a1 * this.y1 - this.a2 * this.y2;
    this.x2 = this.x1; this.x1 = x; this.y2 = this.y1; this.y1 = y;
    return y;
  }
}

// PolyBLEP sawtooth.
const blep = (t: number, dt: number) => {
  if (t < dt) { t /= dt; return t + t - t * t - 1; }
  if (t > 1 - dt) { t = (t - 1) / dt; return t * t + t + t + 1; }
  return 0;
};
class Saw {
  ph = (noise() + 1) / 2;
  next(f: number) {
    const dt = f / SR;
    this.ph += dt;
    if (this.ph >= 1) this.ph -= 1;
    return 2 * this.ph - 1 - blep(this.ph, dt);
  }
}

// ---------------------------------------------------------------------------
// Arrangement
const T = (f: number) => f / FPS;
const tDrop = T(SCENES.hero.from);
const tBreak = T(SCENES.local.from);
const tRapid = T(SCENES.rapid.from);
const tEnd = T(SCENES.end.from);
const tQuestion = T(SCENES.question.from);

const CHORDS = [
  [53, 56, 60], // Fm
  [49, 53, 56], // Db
  [56, 60, 63], // Ab
  [51, 55, 58], // Eb
];
const ROOTS = [41, 37, 44, 39];
const chordAt = (t: number) => Math.floor(t / SBAR) % 4;

const kickTimes: number[] = [];

// Drums ---------------------------------------------------------------------
const kick = (t0: number, g = 1) => {
  kickTimes.push(t0);
  const s0 = sec(t0);
  let ph = 0;
  for (let i = 0; i < sec(0.5); i++) {
    const t = i / SR;
    const f = 44 + 120 * Math.exp(-t / 0.035);
    ph += (2 * Math.PI * f) / SR;
    const env = Math.exp(-t / 0.32);
    const click = i < 90 ? noise() * (1 - i / 90) * 0.25 : 0;
    put(drums, s0 + i, (Math.tanh(Math.sin(ph) * 1.6) * env + click) * 0.85 * g);
  }
};

const clap = (t0: number, g = 1) => {
  const bp = new Biquad().set("bp", 1300, 0.9);
  const s0 = sec(t0);
  for (let i = 0; i < sec(0.35); i++) {
    const t = i / SR;
    let env = Math.exp(-t / 0.13) * 0.6;
    for (const o of [0, 0.011, 0.022]) if (t >= o) env += Math.exp(-(t - o) / 0.007);
    const v = bp.run(noise()) * env * 0.9 * g;
    put(drums, s0 + i, v, 0, 0.35);
  }
};

const hat = (t0: number, open = false, g = 1) => {
  const hp = new Biquad().set("hp", 7500, 0.8);
  const s0 = sec(t0);
  const d = open ? 0.2 : 0.03;
  for (let i = 0; i < sec(d * 5); i++) {
    const t = i / SR;
    put(drums, s0 + i, hp.run(noise()) * Math.exp(-t / d) * 0.28 * g, open ? 0.25 : -0.2, 0.05);
  }
};

const snare = (t0: number, g = 1) => {
  const bp = new Biquad().set("bp", 1900, 0.7);
  const s0 = sec(t0);
  for (let i = 0; i < sec(0.18); i++) {
    const t = i / SR;
    const tone = Math.sin(2 * Math.PI * 190 * t) * Math.exp(-t / 0.05) * 0.5;
    put(drums, s0 + i, (bp.run(noise()) * Math.exp(-t / 0.07) + tone) * 0.55 * g, 0, 0.2);
  }
};

const crash = (t0: number, g = 1) => {
  const hp = new Biquad().set("hp", 4200, 0.6);
  const s0 = sec(t0);
  for (let i = 0; i < sec(2.2); i++) {
    const t = i / SR;
    const v = hp.run(noise()) * Math.exp(-t / 0.7) * 0.22 * g;
    put(drums, s0 + i, v, Math.sin(t * 3) * 0.3, 0.3);
  }
};

const inMain = (t: number) => (t >= tDrop && t < tBreak) || (t >= tRapid && t < tEnd);

for (let b = 0; b < (DURATION / FPS) / SPB; b++) {
  const t = b * SPB;
  const beatInBar = b % 4;
  // Intro heartbeat.
  if (t >= SBAR && t < tQuestion && beatInBar % 2 === 0) kick(t, 0.6);
  if (inMain(t)) {
    kick(t);
    if (beatInBar === 1 || beatInBar === 3) clap(t);
    for (let k = 0; k < 4; k++) {
      const th = t + (k * SPB) / 4;
      if (k === 2) hat(th, true, 0.8);
      else hat(th, false, k === 0 ? 0.5 : 0.8);
    }
  }
  // Breakdown: hats only, thinning.
  if (t >= tBreak && t < tRapid - SBAR) for (let k = 0; k < 2; k++) hat(t + (k * SPB) / 2, false, 0.35);
  // Intro hats.
  if (t >= SBAR * 0.5 && t < tDrop - SBAR) for (let k = 0; k < 4; k++) hat(t + (k * SPB) / 4, false, 0.15 + 0.35 * (t / tDrop));
}
for (const t of [tDrop, T(SCENES.lookup.from), T(SCENES.replies.from), tRapid, tRapid + SBAR]) crash(t, t === tDrop ? 1.3 : 0.8);

// Snare rolls into the drop and into the rapid-fire section.
const roll = (tStart: number, tEndR: number, g = 1) => {
  let t = tStart;
  while (t < tEndR - 0.01) {
    const p = (t - tStart) / (tEndR - tStart);
    snare(t, (0.25 + 0.75 * p) * g);
    const step = p < 0.5 ? SPB / 2 : p < 0.8 ? SPB / 4 : SPB / 8;
    t += step;
  }
};
roll(tDrop - SBAR, tDrop - SPB * 0.25, 0.9);
roll(tRapid - SBAR, tRapid - SPB * 0.25, 0.8);

// Bass ----------------------------------------------------------------------
{
  const saw1 = new Saw();
  const saw2 = new Saw();
  const lp = new Biquad();
  let sub = 0;
  for (let i = 0; i < LEN; i++) {
    const t = i / SR;
    const main = inMain(t);
    const brk = t >= tBreak && t < tRapid;
    const tail = t >= tEnd && t < tEnd + 3.5;
    if (!main && !brk && !tail) { if (i % 64 === 0) lp.set("lp", 200); continue; }
    const root = ROOTS[chordAt(t)];
    const eighth = (t % (SPB / 2)) / (SPB / 2);
    const octave = main && Math.floor(t / (SPB / 2)) % 4 === 3 ? 12 : 0;
    const f = mtof(root + octave);
    const env = main ? Math.exp(-eighth * 2.2) * 0.8 + 0.2 : tail ? Math.exp(-(t - tEnd) / 1.2) : 0.7;
    if (i % 32 === 0) lp.set("lp", main ? 300 + 1400 * Math.exp(-eighth * 4) : 260, 1.2);
    const v = lp.run(saw1.next(f) * 0.6 + saw2.next(f * 1.006) * 0.6);
    sub += (2 * Math.PI * mtof(root - 12)) / SR;
    put(music, i, (v * 0.42 + Math.sin(sub) * 0.3) * env);
  }
}

// Pad -----------------------------------------------------------------------
{
  const voices = Array.from({ length: 6 }, () => new Saw());
  const lpL = new Biquad();
  const lpR = new Biquad();
  for (let i = 0; i < LEN; i++) {
    const t = i / SR;
    const chord = CHORDS[chordAt(t)];
    const barPos = (t % SBAR) / SBAR;
    const swell = Math.min(1, barPos * 6) * (1 - Math.max(0, barPos - 0.9) * 4);
    let cutoff = 700;
    let g = 0.16;
    if (t < tQuestion) { cutoff = 350 + 450 * (t / tQuestion); g = 0.2 * Math.min(1, t / 1.5); }
    else if (t < tDrop) cutoff = 800 + 2000 * ((t - tQuestion) / (tDrop - tQuestion));
    else if (t < tBreak) cutoff = 1600;
    else if (t < tRapid) { cutoff = 900 + 1400 * ((t - tBreak) / (tRapid - tBreak)); g = 0.22; }
    else if (t < tEnd) cutoff = 2400;
    else { cutoff = 1800 - 1400 * Math.min(1, (t - tEnd) / 4); g = 0.26 * Math.exp(-(t - tEnd) / 2.6); }
    if (t >= tDrop - SPB * 0.25 && t < tDrop) g = 0;
    if (i % 64 === 0) { lpL.set("lp", cutoff, 0.8); lpR.set("lp", cutoff * 1.05, 0.8); }
    const endChord = t >= tEnd ? CHORDS[0] : chord;
    let l = 0;
    let r = 0;
    for (let v = 0; v < 6; v++) {
      const note = endChord[v % 3] + (v >= 3 ? 12 : 0);
      const s = voices[v].next(mtof(note) * (1 + (v - 2.5) * 0.0025));
      if (v % 2) l += s; else r += s;
    }
    const e = (t >= tEnd ? 1 : swell) * g;
    const lv = lpL.run(l) * e;
    const rv = lpR.run(r) * e;
    music[0][i] += lv;
    music[1][i] += rv;
    verbSend[i] += (lv + rv) * 0.25;
  }
}

// Arp -----------------------------------------------------------------------
{
  const pattern = [0, 1, 2, 3, 2, 1, 3, 1];
  const step = SPB / 4;
  for (let n = 0; n * step < DURATION / FPS; n++) {
    const t0 = n * step;
    const active = (t0 >= tDrop + SBAR * 1.5 && t0 < tEnd) || (t0 >= tQuestion + SBAR && t0 < tDrop - SPB * 0.25);
    if (!active) continue;
    const brk = t0 >= tBreak && t0 < tRapid;
    const chord = CHORDS[chordAt(t0)];
    const notes = [chord[0] + 12, chord[1] + 12, chord[2] + 12, chord[0] + 24];
    const f = mtof(notes[pattern[n % pattern.length]]);
    const lp = new Biquad().set("lp", brk ? 1500 : t0 < tDrop ? 1200 : 3200, 2);
    const s0 = sec(t0);
    const pan = n % 2 ? 0.45 : -0.45;
    let ph = 0;
    const g = t0 < tDrop ? 0.06 : brk ? 0.11 : 0.09;
    for (let i = 0; i < sec(0.25); i++) {
      const t = i / SR;
      ph += f / SR;
      const sq = (ph % 1 < 0.5 ? 1 : -1) * 0.5 + Math.sin(2 * Math.PI * ph) * 0.5;
      const v = lp.run(sq) * Math.exp(-t / 0.07) * g;
      put(music, s0 + i, v, pan, 0.5);
      put(music, s0 + i + sec(SPB * 0.75), v * 0.35, -pan, 0.3);
    }
  }
}

// SFX -----------------------------------------------------------------------
const PING = [1318.5, 1568, 1760, 1975.5];
const BLIP = [mtof(77), mtof(80), mtof(84), mtof(87)];

const nextBigHit = (f: number) => {
  const h = HITS.find((x) => x.f > f + 30 && (x.kind === "boom" || (x.kind === "impact" && x.gain! >= 0.7)));
  return h ? T(h.f) : T(f) + 1;
};

const renderHit = (h: Hit) => {
  const t0 = T(h.f);
  const s0 = sec(t0);
  const g = h.gain ?? 1;
  const pan = h.pan ?? 0;
  const pitch = h.pitch ?? 0;
  switch (h.kind) {
    case "ping": {
      const f = PING[pitch % 4];
      for (let i = 0; i < sec(0.35); i++) {
        const t = i / SR;
        const v = (Math.sin(2 * Math.PI * f * t) + 0.3 * Math.sin(2 * Math.PI * f * 2.76 * t) * Math.exp(-t / 0.03)) * Math.exp(-t / 0.09);
        put(sfx, s0 + i, v * 0.22 * g, pan, 0.3);
      }
      break;
    }
    case "blip": {
      const f = BLIP[pitch % 4];
      for (let i = 0; i < sec(0.2); i++) {
        const t = i / SR;
        const ff = f * (1 + 0.5 * Math.exp(-t / 0.01));
        const v = Math.sign(Math.sin(2 * Math.PI * ff * t)) * 0.4 + Math.sin(2 * Math.PI * ff * t) * 0.6;
        put(sfx, s0 + i, v * Math.exp(-t / 0.05) * 0.2 * g, (pitch - 1.5) * 0.4, 0.3);
      }
      break;
    }
    case "click": {
      const hp = new Biquad().set("hp", 2500 + pitch * 800, 1);
      for (let i = 0; i < sec(0.03); i++) {
        const t = i / SR;
        put(sfx, s0 + i, (hp.run(noise()) + Math.sin(2 * Math.PI * 3200 * t) * 0.3) * Math.exp(-t / 0.004) * 0.35 * g, (pitch - 1) * 0.2);
      }
      break;
    }
    case "tick": {
      for (let i = 0; i < sec(0.06); i++) {
        const t = i / SR;
        put(sfx, s0 + i, Math.sin(2 * Math.PI * 2600 * t) * Math.exp(-t / 0.012) * 0.25 * g, pan, 0.4);
      }
      break;
    }
    case "pop": {
      const base = 380 * Math.pow(1.12, pitch);
      let ph = 0;
      for (let i = 0; i < sec(0.12); i++) {
        const t = i / SR;
        ph += (2 * Math.PI * base * (1 + 1.4 * Math.min(1, t / 0.03))) / SR;
        put(sfx, s0 + i, Math.sin(ph) * Math.exp(-t / 0.035) * 0.3 * g, (pitch % 3 - 1) * 0.3, 0.2);
      }
      break;
    }
    case "whoosh":
    case "whooshBig": {
      const big = h.kind === "whooshBig";
      const dur = big ? 0.6 : 0.45;
      const peak = big ? 10 / FPS : dur * 0.5;
      const bp = new Biquad();
      const bp2 = new Biquad();
      for (let i = 0; i < sec(dur); i++) {
        const t = i / SR;
        const x = t < peak ? t / peak : 1 - (t - peak) / (dur - peak);
        const env = Math.pow(Math.max(0, x), big ? 2.2 : 1.6);
        if (i % 32 === 0) {
          const fc = 250 + 4200 * Math.pow(Math.max(0, x), 1.5);
          bp.set("bp", fc, 0.9);
          bp2.set("bp", fc * 1.6, 1.2);
        }
        const n = noise();
        const v = (bp.run(n) + bp2.run(n) * 0.5) * env * (big ? 0.9 : 0.6) * g;
        const p = pan + (t < peak ? -1 : 1) * 0.5 * Math.sign(pan || 1) * (1 - env);
        put(sfx, s0 + i, v, Math.max(-1, Math.min(1, p)), 0.25);
      }
      break;
    }
    case "impact": {
      const lp = new Biquad().set("lp", 2200, 0.7);
      let ph = 0;
      for (let i = 0; i < sec(1.2); i++) {
        const t = i / SR;
        ph += (2 * Math.PI * (38 + 50 * Math.exp(-t / 0.06))) / SR;
        const sub = Math.sin(ph) * Math.exp(-t / 0.45);
        const crack = lp.run(noise()) * Math.exp(-t / 0.05);
        put(sfx, s0 + i, (Math.tanh(sub * 1.4) * 0.6 + crack * 0.45) * g * 0.7, 0, 0.4);
      }
      break;
    }
    case "boom": {
      const lp = new Biquad().set("lp", 900, 0.7);
      let ph = 0;
      for (let i = 0; i < sec(3.5); i++) {
        const t = i / SR;
        ph += (2 * Math.PI * (30 + 45 * Math.exp(-t / 0.12))) / SR;
        const sub = Math.tanh(Math.sin(ph) * 2) * Math.exp(-t / 1.1);
        const wash = lp.run(noise()) * Math.exp(-t / 0.5) * 0.4;
        put(sfx, s0 + i, (sub * 0.7 + wash) * g * 0.75, 0, 0.6);
      }
      break;
    }
    case "riser": {
      const dur = nextBigHit(h.f) - t0;
      const bp = new Biquad();
      const saw = new Saw();
      for (let i = 0; i < sec(dur); i++) {
        const t = i / SR;
        const p = t / dur;
        if (i % 32 === 0) bp.set("bp", 200 * Math.pow(40, p), 2.5);
        const env = Math.pow(p, 2.2);
        const tone = saw.next(110 * Math.pow(8, p)) * 0.12;
        put(sfx, s0 + i, (bp.run(noise()) * 1.2 + tone) * env * 0.5 * g, Math.sin(t * 8) * 0.4 * p, 0.3);
      }
      break;
    }
    case "revCymbal": {
      const dur = nextBigHit(h.f) - t0;
      const hp = new Biquad().set("hp", 5000, 0.6);
      for (let i = 0; i < sec(dur); i++) {
        const t = i / SR;
        const p = t / dur;
        put(sfx, s0 + i, hp.run(noise()) * Math.pow(p, 3) * 0.55 * g, 0, 0.5);
      }
      break;
    }
    case "lock": {
      for (let i = 0; i < sec(0.3); i++) {
        const t = i / SR;
        const metal = (Math.sin(2 * Math.PI * 1850 * t) + Math.sin(2 * Math.PI * 2710 * t) * 0.7 + Math.sin(2 * Math.PI * 4120 * t) * 0.4) * Math.exp(-t / 0.035);
        const thunk = Math.sin(2 * Math.PI * 130 * t) * Math.exp(-t / 0.06);
        const click = i < 200 ? noise() * (1 - i / 200) : 0;
        put(sfx, s0 + i, (metal * 0.25 + thunk * 0.6 + click * 0.5) * g * 0.6, 0, 0.35);
      }
      break;
    }
    case "glitch": {
      let f = 200;
      for (let i = 0; i < sec(0.2); i++) {
        const t = i / SR;
        if (i % sec(0.018) === 0) f = 120 + ((noise() + 1) / 2) * 1800;
        const crushed = Math.round(Math.sign(Math.sin(2 * Math.PI * f * t)) * 3) / 3;
        put(sfx, s0 + i, crushed * 0.16 * g * (1 - t / 0.2), noise() * 0.5);
      }
      break;
    }
  }
};
HITS.forEach(renderHit);

// ---------------------------------------------------------------------------
// Reverb (Freeverb-style, mono in -> stereo out).
const verb = mk();
{
  const combs = [1557, 1617, 1491, 1422, 1277, 1356, 1188, 1116];
  const aps = [556, 441, 341, 225];
  for (let ch = 0; ch < 2; ch++) {
    const spread = ch * 23;
    const cBufs = combs.map((d) => new Float32Array(d + spread));
    const cIdx = combs.map(() => 0);
    const cLp = combs.map(() => 0);
    const aBufs = aps.map((d) => new Float32Array(d + spread));
    const aIdx = aps.map(() => 0);
    const fb = 0.84;
    const damp = 0.3;
    const out = verb[ch];
    for (let i = 0; i < LEN; i++) {
      const x = verbSend[i] * 0.015;
      let y = 0;
      for (let c = 0; c < cBufs.length; c++) {
        const buf = cBufs[c];
        const o = buf[cIdx[c]];
        cLp[c] = o * (1 - damp) + cLp[c] * damp;
        buf[cIdx[c]] = x + cLp[c] * fb;
        cIdx[c] = (cIdx[c] + 1) % buf.length;
        y += o;
      }
      for (let a = 0; a < aBufs.length; a++) {
        const buf = aBufs[a];
        const o = buf[aIdx[a]];
        buf[aIdx[a]] = y + o * 0.5;
        aIdx[a] = (aIdx[a] + 1) % buf.length;
        y = o - y;
      }
      out[i] = y;
    }
  }
}

// ---------------------------------------------------------------------------
// Sidechain + master.
kickTimes.sort((a, b) => a - b);
const out = mk();
{
  let k = 0;
  for (let i = 0; i < LEN; i++) {
    const t = i / SR;
    while (k + 1 < kickTimes.length && kickTimes[k + 1] <= t) k++;
    const dt = kickTimes.length && kickTimes[k] <= t ? t - kickTimes[k] : 99;
    const duck = 1 - 0.65 * Math.exp(-dt / 0.11);
    const gate = t >= tDrop - SPB * 0.2 && t < tDrop ? 0.15 : 1;
    for (let ch = 0; ch < 2; ch++) {
      const m = music[ch][i] * duck * gate;
      const d = drums[ch][i] * gate;
      out[ch][i] = d * 0.9 + m + sfx[ch][i] * 0.85 + verb[ch][i] * 0.9;
    }
  }
}
let peak = 0;
for (let ch = 0; ch < 2; ch++) for (let i = 0; i < LEN; i++) {
  const v = Math.tanh(out[ch][i] * 0.55);
  out[ch][i] = v;
  peak = Math.max(peak, Math.abs(v));
}
const norm = 0.93 / (peak || 1);
const fadeStart = LEN - sec(0.6);

// ---------------------------------------------------------------------------
// WAV writer.
const data = Buffer.alloc(LEN * 4);
for (let i = 0; i < LEN; i++) {
  const fade = i > fadeStart ? 1 - (i - fadeStart) / (LEN - fadeStart) : 1;
  const fadeIn = Math.min(1, i / 200);
  for (let ch = 0; ch < 2; ch++) {
    const s = Math.max(-1, Math.min(1, out[ch][i] * norm * fade * fadeIn));
    data.writeInt16LE(Math.round(s * 32767), i * 4 + ch * 2);
  }
}
const header = Buffer.alloc(44);
header.write("RIFF", 0);
header.writeUInt32LE(36 + data.length, 4);
header.write("WAVE", 8);
header.write("fmt ", 12);
header.writeUInt32LE(16, 16);
header.writeUInt16LE(1, 20);
header.writeUInt16LE(2, 22);
header.writeUInt32LE(SR, 24);
header.writeUInt32LE(SR * 4, 28);
header.writeUInt16LE(4, 32);
header.writeUInt16LE(16, 34);
header.write("data", 36);
header.writeUInt32LE(data.length, 40);

const here = dirname(fileURLToPath(import.meta.url));
const dest = join(here, "..", "public", "soundtrack.wav");
writeFileSync(dest, Buffer.concat([header, data]));
console.log(`soundtrack.wav: ${(LEN / SR).toFixed(2)}s, ${HITS.length} sfx hits, ${kickTimes.length} kicks, peak ${peak.toFixed(3)}`);
