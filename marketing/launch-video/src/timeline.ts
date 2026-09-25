// Shared by the Remotion scenes and scripts/synth.ts, so this file must stay
// free of React / Remotion imports.
//
// The bed is the pidgy.chat site track (golden-hour-haze.mp3): 80 BPM, one
// bar every 3.0 s, first downbeat 0.05 s into the file. We trim those 3
// frames off so bar N starts exactly at N * 3 s, and every scene below starts
// on a bar line.

export const FPS = 60;
export const WIDTH = 1920;
export const HEIGHT = 1080;
export const DURATION = 60 * FPS;

export const BAR_S = 3;
export const BEAT_S = BAR_S / 4;
export const BAR = BAR_S * FPS; // 180 frames
export const BEAT = BEAT_S * FPS; // 45 frames
export const MUSIC_TRIM = 3; // frames
export const MUSIC_LOOP_AT = 10 * BAR; // the file holds exactly 10 bars

export const s = (sec: number) => Math.round(sec * FPS);

export type SceneId = "inbox" | "buried" | "hero" | "queue" | "find" | "prep" | "values" | "channels" | "end";

export const SCENES: Record<SceneId, { from: number; dur: number }> = {
  inbox: { from: 0, dur: 2 * BAR }, // 0-6s     1,571 contacts. A forty-screen inbox.
  buried: { from: 2 * BAR, dur: 2 * BAR }, // 6-12s    ...buried in a group called "stuff".
  hero: { from: 4 * BAR, dur: 3 * BAR }, // 12-21s   sky, Pidgy, every message finds its way home
  queue: { from: 7 * BAR, dur: 3 * BAR }, // 21-30s   know who's waiting on you
  find: { from: 10 * BAR, dur: 2 * BAR }, // 30-36s   find any message
  prep: { from: 12 * BAR, dur: 2 * BAR }, // 36-42s   prep before you reply
  values: { from: 14 * BAR, dur: 2 * BAR }, // 42-48s   pidgy notices. you decide. local.
  channels: { from: 16 * BAR, dur: 2 * BAR }, // 48-54s   telegram today, more next
  end: { from: 18 * BAR, dur: 2 * BAR }, // 54-60s   lockup
};

export const at = (id: SceneId, sec: number) => SCENES[id].from + s(sec);

// Typing.
export const FIND_QUERY = "where did I send the wallet to Aman";
export const FIND_TYPE_START = at("find", 1.0);
export const findCharFrame = (i: number) => FIND_TYPE_START + Math.round(i * 2.6);
export const FIND_RESULT = at("find", 3.0); // bar line

export const PREP_QUERY = "what did we decide with Akhil?";
export const PREP_TYPE_START = at("prep", 0.2);
export const prepCharFrame = (i: number) => PREP_TYPE_START + Math.round(i * 2.1);
export const PREP_RESULT = at("prep", 1.5); // half-bar

export const HOTKEY = [at("find", 0.15), at("find", 0.3), at("find", 0.45)];

// Cursor clicks in the dashboard: sidebar "Reply queue" on the bar line,
// then the top row on the next beat pair.
export const QUEUE_CLICKS = [at("queue", 3.0), at("queue", 4.5)];

export type ChannelId = "telegram" | "slack" | "gmail" | "whatsapp";
export const CHANNEL_ORDER: ChannelId[] = ["telegram", "slack", "gmail", "whatsapp"];
export const CHANNEL_AT = CHANNEL_ORDER.map((_, i) => at("channels", 1.5 + i * BEAT_S));

// Birds crossing the sky: [start frame, duration, flock size].
export const FLIGHTS: [number, number, number][] = [
  [at("hero", 0.3), s(7), 5],
  [at("end", 0.2), s(5.5), 3],
];

// ---------------------------------------------------------------------------
// Soft sound design, mixed under the music by scripts/synth.ts.
export type HitKind = "key" | "thock" | "pop" | "air" | "wings" | "chime" | "tick" | "click";
export type Hit = { f: number; kind: HitKind; gain?: number; pitch?: number; pan?: number };

const hits: Hit[] = [];
const add = (h: Hit) => hits.push(h);

add({ f: at("inbox", 0.3), kind: "tick", gain: 0.5 });
add({ f: at("inbox", 2.0), kind: "tick", gain: 0.5 });
add({ f: at("buried", 0.95), kind: "pop", gain: 0.6, pitch: 0 });
add({ f: SCENES.hero.from - s(0.6), kind: "air", gain: 0.8 });
FLIGHTS.forEach(([f, d]) => add({ f: f + s(0.5), kind: "wings", gain: 0.55, pan: -0.4 }));
add({ f: at("hero", 1.5), kind: "chime", gain: 0.5, pitch: 0 });
QUEUE_CLICKS.forEach((f) => add({ f, kind: "click", gain: 0.8 }));
add({ f: QUEUE_CLICKS[1] + 4, kind: "pop", gain: 0.3, pitch: 2 });
HOTKEY.forEach((f, i) => add({ f, kind: "thock", gain: 0.6, pitch: i }));
for (let i = 0; i < FIND_QUERY.length; i++) if (FIND_QUERY[i] !== " ") add({ f: findCharFrame(i), kind: "key", gain: 0.35, pitch: i % 3 });
add({ f: FIND_RESULT, kind: "pop", gain: 0.55, pitch: 2 });
for (let i = 0; i < PREP_QUERY.length; i++) if (PREP_QUERY[i] !== " ") add({ f: prepCharFrame(i), kind: "key", gain: 0.35, pitch: i % 3 });
add({ f: PREP_RESULT, kind: "pop", gain: 0.55, pitch: 1 });
CHANNEL_AT.forEach((f, i) => add({ f, kind: "pop", gain: 0.4, pitch: i }));
(["queue", "find", "prep", "values", "channels", "end"] as SceneId[]).forEach((id) =>
  add({ f: SCENES[id].from - s(0.35), kind: "air", gain: 0.35 })
);
add({ f: at("end", 3.0), kind: "chime", gain: 0.7, pitch: 1 });

export const HITS: Hit[] = hits.sort((a, b) => a.f - b.f);
