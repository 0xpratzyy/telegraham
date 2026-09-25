import { Easing, random } from "remotion";

export const clamp = (x: number, a = 0, b = 1) => Math.min(b, Math.max(a, x));
export const lerp = (a: number, b: number, t: number) => a + (b - a) * t;

export const ease = {
  outExpo: (t: number) => (t >= 1 ? 1 : 1 - Math.pow(2, -10 * t)),
  inExpo: (t: number) => (t <= 0 ? 0 : Math.pow(2, 10 * t - 10)),
  outCubic: (t: number) => 1 - Math.pow(1 - t, 3),
  inCubic: (t: number) => t * t * t,
  inOutCubic: (t: number) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2),
  inOutExpo: (t: number) =>
    t <= 0 ? 0 : t >= 1 ? 1 : t < 0.5 ? Math.pow(2, 20 * t - 10) / 2 : (2 - Math.pow(2, -20 * t + 10)) / 2,
  outBack: (t: number) => {
    const c1 = 1.9;
    const c3 = c1 + 1;
    return 1 + c3 * Math.pow(t - 1, 3) + c1 * Math.pow(t - 1, 2);
  },
  // The "motion designer" curve: fast attack, long silky settle.
  snap: Easing.bezier(0.16, 1, 0.3, 1),
  swoop: Easing.bezier(0.7, 0, 0.2, 1),
};

/** 0..1 progress of `frame` through [start, start+dur], eased. */
export const prog = (frame: number, start: number, dur: number, fn: (t: number) => number = ease.snap) =>
  fn(clamp((frame - start) / dur));

/** Damped spring impulse triggered at `at`, returns ~0 at rest, peaks at 1. */
export const kick = (frame: number, at: number, decay = 10, freq = 0.35) => {
  const t = frame - at;
  if (t < 0) return 0;
  return Math.exp(-t / decay) * Math.cos(t * freq);
};

/** Exponential decay pulse (no oscillation). */
export const pulse = (frame: number, at: number, decay = 8) => {
  const t = frame - at;
  return t < 0 ? 0 : Math.exp(-t / decay);
};

/** Smooth pseudo-random wobble for camera shake. */
export const wobble = (frame: number, seed: string, speed = 0.25) => {
  const i = Math.floor(frame * speed);
  const f = frame * speed - i;
  const a = random(`${seed}-${i}`) * 2 - 1;
  const b = random(`${seed}-${i + 1}`) * 2 - 1;
  const s = f * f * (3 - 2 * f);
  return lerp(a, b, s);
};

export const rnd = (seed: string | number, min = 0, max = 1) => lerp(min, max, random(String(seed)));
