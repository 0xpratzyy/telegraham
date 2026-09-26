// Shared by the Remotion scenes and scripts/synth.ts, so this file must stay
// free of React / Remotion imports. Every visual hit and every sound is
// derived from the same numbers here, which is what keeps picture and music
// locked together.

export const FPS = 60;
export const WIDTH = 1920;
export const HEIGHT = 1080;
export const BPM = 120;
export const BEAT = (FPS * 60) / BPM; // 30 frames
export const BAR = BEAT * 4; // 120 frames
export const DURATION = 60 * FPS; // 3600 frames

export const beat = (n: number) => Math.round(n * BEAT);
export const bar = (n: number) => Math.round(n * BAR);

export type SceneId =
  | "noise"
  | "question"
  | "hero"
  | "tagline"
  | "lookup"
  | "topics"
  | "replies"
  | "recap"
  | "local"
  | "rapid"
  | "end";

export const SCENES: Record<SceneId, { from: number; dur: number }> = {
  noise: { from: 0, dur: bar(2) }, // 0-4s
  question: { from: bar(2), dur: bar(2) }, // 4-8s
  hero: { from: bar(4), dur: bar(3) }, // 8-14s  (drop)
  tagline: { from: bar(7), dur: bar(2) }, // 14-18s
  lookup: { from: bar(9), dur: bar(3) }, // 18-24s
  topics: { from: bar(12), dur: bar(3) }, // 24-30s
  replies: { from: bar(15), dur: bar(3) }, // 30-36s
  recap: { from: bar(18), dur: bar(3) }, // 36-42s
  local: { from: bar(21), dur: bar(4) }, // 42-50s  (breakdown)
  rapid: { from: bar(25), dur: bar(3) }, // 50-56s
  end: { from: bar(28), dur: bar(2) }, // 56-60s
};

export const sceneEnd = (id: SceneId) => SCENES[id].from + SCENES[id].dur;

// ---------------------------------------------------------------------------
// Cold open: notification avalanche. Spawn times accelerate and are quantised
// to 16th notes so the pings in the soundtrack form a rhythm.
export const NOISE_BUBBLES = 96;
const SIXTEENTH = BEAT / 4;
export const bubbleSpawnFrame = (i: number) => {
  if (i === 0) return 8;
  const t = Math.pow(i / NOISE_BUBBLES, 0.55);
  const raw = 60 + t * (SCENES.noise.dur - 90);
  return Math.round(raw / (SIXTEENTH / 2)) * (SIXTEENTH / 2);
};

// ---------------------------------------------------------------------------
// "The question": typed query, one keystroke every 3 frames.
export const QUESTION_TEXT = "where did I send that wallet address?";
export const QUESTION_TYPE_START = SCENES.question.from + 22;
export const QUESTION_CHAR_FRAMES = 3;
export const questionCharFrame = (i: number) =>
  QUESTION_TYPE_START + i * QUESTION_CHAR_FRAMES + (i % 7 === 3 ? 2 : 0);
// Channel roll-call on 8th notes near the end of the question bar.
export const QUESTION_CHANNEL_FLASH = [0, 1, 2, 3].map(
  (i) => SCENES.question.from + beat(4) + beat(0.5) * i + beat(0.5)
);
export const IMPLODE_START = SCENES.question.from + beat(6.5);
export const DROP = SCENES.hero.from;

// ---------------------------------------------------------------------------
// Feature launcher query.
export const LOOKUP_QUERY = "wallet address I sent Nova";
export const LOOKUP_TYPE_START = SCENES.lookup.from + 34;
export const lookupCharFrame = (i: number) => LOOKUP_TYPE_START + i * 2;

// Reply draft typing.
export const DRAFT_TEXT = "Yes — sending the signed deck + wallet in 10 min.";
export const DRAFT_TYPE_START = SCENES.replies.from + beat(7.5);
export const draftCharFrame = (i: number) => DRAFT_TYPE_START + Math.floor(i * 1.5);

// Recap task checkoffs, on beats.
export const RECAP_CHECKS = [0, 1, 2, 3].map((i) => SCENES.recap.from + beat(6 + i));

// Local-first lock snap.
export const LOCK_SNAP = SCENES.local.from + beat(10);

// Rapid-fire words: one per beat.
export const RAPID_WORDS: { text: string; channel?: ChannelId; stutter?: boolean }[] = [
  { text: "Find." },
  { text: "Triage." },
  { text: "Reply." },
  { text: "Done." },
  { text: "Telegram", channel: "telegram" },
  { text: "Slack", channel: "slack" },
  { text: "Gmail", channel: "gmail" },
  { text: "WhatsApp", channel: "whatsapp" },
  { text: "Every chat." },
  { text: "Every chat.", stutter: true },
  { text: "One Pidgy." },
  { text: "One Pidgy.", stutter: true },
];
export const rapidWordFrame = (i: number) => SCENES.rapid.from + beat(i);

export type ChannelId = "telegram" | "slack" | "gmail" | "whatsapp";
export const CHANNEL_ORDER: ChannelId[] = ["telegram", "slack", "gmail", "whatsapp"];

// ---------------------------------------------------------------------------
// Sound design hit list, consumed by scripts/synth.ts.
export type HitKind =
  | "ping"
  | "blip"
  | "click"
  | "whoosh"
  | "whooshBig"
  | "impact"
  | "boom"
  | "riser"
  | "revCymbal"
  | "lock"
  | "pop"
  | "glitch"
  | "tick";

export type Hit = { f: number; kind: HitKind; gain?: number; pitch?: number; pan?: number };

const hits: Hit[] = [];
const add = (h: Hit) => hits.push(h);

// Cold open pings, gain ramps as the pile grows.
for (let i = 0; i < NOISE_BUBBLES; i++) {
  const f = bubbleSpawnFrame(i);
  if (i > 0 && f === bubbleSpawnFrame(i - 1)) continue;
  add({ f, kind: "ping", gain: i === 0 ? 1 : 0.25 + 0.35 * (i / NOISE_BUBBLES), pitch: i % 4, pan: ((i * 37) % 11) / 5.5 - 1 });
}
add({ f: SCENES.noise.dur - 2, kind: "glitch", gain: 0.9 });

// Question typing + channel roll-call + implode.
for (let i = 0; i < QUESTION_TEXT.length; i++) {
  if (QUESTION_TEXT[i] !== " ") add({ f: questionCharFrame(i), kind: "click", gain: 0.55, pitch: i % 3 });
}
QUESTION_CHANNEL_FLASH.forEach((f, i) => add({ f, kind: "blip", pitch: i, gain: 0.8 }));
add({ f: SCENES.question.from + beat(1), kind: "riser", gain: 1 });
add({ f: IMPLODE_START, kind: "whoosh", gain: 0.8, pan: 0 });

// Drop + hero.
add({ f: DROP, kind: "boom", gain: 1.2 });
add({ f: DROP, kind: "impact", gain: 1 });
add({ f: DROP + beat(2.5), kind: "tick", gain: 0.7 }); // glint
add({ f: DROP + beat(4), kind: "whoosh", gain: 0.6, pan: 0.6 }); // mascot slides
for (let i = 0; i < 5; i++) add({ f: DROP + beat(4.5) + i * 4, kind: "pop", gain: 0.5, pitch: i });

// Tagline.
add({ f: SCENES.tagline.from, kind: "impact", gain: 0.7 });
add({ f: SCENES.tagline.from + beat(2), kind: "impact", gain: 0.6 });
CHANNEL_ORDER.forEach((_, i) => add({ f: SCENES.tagline.from + beat(4.5 + i * 0.5), kind: "blip", pitch: i, gain: 0.7 }));

// Whip pans into every feature scene and beyond.
(["lookup", "topics", "replies", "recap", "local"] as SceneId[]).forEach((id, i) => {
  add({ f: SCENES[id].from - 10, kind: "whooshBig", gain: 0.9, pan: i % 2 ? -0.5 : 0.5 });
});

// Lookup.
for (let i = 0; i < LOOKUP_QUERY.length; i++) {
  if (LOOKUP_QUERY[i] !== " ") add({ f: lookupCharFrame(i), kind: "click", gain: 0.4, pitch: i % 3 });
}
for (let i = 0; i < 4; i++) add({ f: SCENES.lookup.from + beat(4) + i * 6, kind: "pop", gain: 0.45, pitch: i });
add({ f: SCENES.lookup.from + beat(7), kind: "impact", gain: 0.55 });

// Topics: edges draw on.
for (let i = 0; i < 8; i++) add({ f: SCENES.topics.from + beat(2) + i * 7, kind: "pop", gain: 0.35, pitch: i % 5 });
add({ f: SCENES.topics.from + beat(6), kind: "impact", gain: 0.45 });

// Replies: shuffle + sort + draft.
for (let i = 0; i < 6; i++) add({ f: SCENES.replies.from + beat(3) + i * 5, kind: "tick", gain: 0.45 });
add({ f: SCENES.replies.from + beat(5), kind: "whoosh", gain: 0.5, pan: -0.3 });
for (let i = 0; i < DRAFT_TEXT.length; i += 2) add({ f: draftCharFrame(i), kind: "click", gain: 0.25, pitch: i % 3 });

// Recap.
RECAP_CHECKS.forEach((f, i) => add({ f, kind: "pop", gain: 0.7, pitch: i + 2 }));

// Local-first.
add({ f: LOCK_SNAP, kind: "lock", gain: 1 });
add({ f: LOCK_SNAP, kind: "impact", gain: 0.7 });

// Rapid fire.
RAPID_WORDS.forEach((w, i) => {
  add({ f: rapidWordFrame(i), kind: w.stutter ? "glitch" : "impact", gain: w.stutter ? 0.5 : 0.75 });
});
add({ f: SCENES.rapid.from - beat(2), kind: "riser", gain: 0.7 });

// End card.
add({ f: SCENES.end.from - beat(2), kind: "revCymbal", gain: 1 });
add({ f: SCENES.end.from, kind: "boom", gain: 1.3 });
add({ f: SCENES.end.from, kind: "impact", gain: 1 });
add({ f: SCENES.end.from + beat(2), kind: "pop", gain: 0.5, pitch: 4 });

export const HITS: Hit[] = hits.sort((a, b) => a.f - b.f);
