import React from "react";
import { AbsoluteFill, random } from "remotion";
import { clamp, ease, lerp } from "../fx/easing";
import { C, FONT } from "../theme";
import { Glyph } from "../ui/Glyph";
import { CHANNEL_ORDER, NOISE_BUBBLES, bubbleSpawnFrame, type ChannelId } from "../timeline";

const SENDERS = [
  "Nova Labs · BD", "Alex Kim", "#partnerships", "Priya (Orbit)", "Dmitri", "Founders Chat", "Sara @ Helix", "#launch-war-room",
  "Investor Updates", "Marco", "Community Mods", "Jules · Ops", "Kenji", "Delta DAO", "#design", "Lena",
];
const SNIPPETS = [
  "did you see the deck?", "can you send the wallet again?", "ping — still on for 3pm?", "who owns this follow-up?",
  "contract address pls 🙏", "any update on the intro?", "re: invoice Q3", "bumping this ↑", "are we live tomorrow?",
  "can you review the terms", "gm! quick q", "where's the link from yesterday?", "need your sign-off", "left you a voice note",
  "sent the doc, lmk", "call moved to 4:30",
];

type Bubble = {
  i: number;
  channel: ChannelId;
  x: number;
  y: number;
  z: number;
  rot: number;
  spawn: number;
  sender: string;
  text: string;
  unread: number;
};

export const BUBBLES: Bubble[] = Array.from({ length: NOISE_BUBBLES }, (_, i) => {
  const r = (k: string) => random(`b${i}${k}`);
  const first = i === 0;
  return {
    i,
    channel: first ? "telegram" : CHANNEL_ORDER[Math.floor(r("c") * 4)],
    x: first ? 960 : lerp(60, 1860, r("x")),
    y: first ? 540 : lerp(60, 1020, r("y")),
    z: first ? 1 : Math.pow(r("z"), 0.8),
    rot: first ? 0 : (r("r") - 0.5) * 14,
    spawn: bubbleSpawnFrame(i),
    sender: SENDERS[Math.floor(r("s") * SENDERS.length)],
    text: SNIPPETS[Math.floor(r("t") * SNIPPETS.length)],
    unread: 1 + Math.floor(r("u") * 24),
  };
});

const BubbleCard: React.FC<{ b: Bubble; appear: number; jitter: number }> = ({ b, appear, jitter }) => (
  <div
    style={{
      width: 420,
      padding: "18px 22px",
      borderRadius: 22,
      background: "rgba(43,43,43,0.94)",
      border: `1px solid ${C.border3}`,
      boxShadow: "0 18px 36px rgba(0,0,0,0.5)",
      display: "flex",
      gap: 16,
      alignItems: "center",
      fontFamily: FONT.ui,
      color: C.fg1,
      transform: `scale(${appear}) rotate(${b.rot + jitter}deg)`,
      position: "relative",
    }}
  >
    <Glyph id={b.channel} size={50} tile />
    <div style={{ flex: 1, minWidth: 0 }}>
      <div style={{ fontSize: 19, fontWeight: 650, display: "flex", justifyContent: "space-between" }}>
        <span>{b.sender}</span>
        <span style={{ color: C.fg3, fontWeight: 500, fontSize: 15 }}>now</span>
      </div>
      <div style={{ fontSize: 18, color: C.fg2, marginTop: 4, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
        {b.text}
      </div>
    </div>
    <div
      style={{
        position: "absolute",
        top: -12,
        right: -12,
        minWidth: 36,
        height: 36,
        padding: "0 10px",
        borderRadius: 18,
        background: C.danger,
        color: "white",
        fontWeight: 700,
        fontSize: 18,
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        boxShadow: "0 4px 12px rgba(214,61,67,0.5)",
      }}
    >
      {b.unread}
    </div>
  </div>
);

/**
 * The notification avalanche. `t` is the scene-local frame that drives spawn
 * state; `implode` (0..1) sucks every bubble into the centre.
 */
export const NoiseField: React.FC<{ t: number; implode?: number; agitation?: number; layer: "back" | "front" }> = ({
  t,
  implode = 0,
  agitation = 0,
  layer,
}) => {
  return (
    <AbsoluteFill>
      {layer === "back" ? (
        <>
          <AbsoluteFill style={{ filter: "blur(4px)" }}>{renderBubbles(t, implode, agitation, "far")}</AbsoluteFill>
          <AbsoluteFill>{renderBubbles(t, implode, agitation, "mid")}</AbsoluteFill>
        </>
      ) : (
        <AbsoluteFill style={{ filter: "blur(3px)" }}>{renderBubbles(t, implode, agitation, "front")}</AbsoluteFill>
      )}
    </AbsoluteFill>
  );
};

// One blur per depth band instead of one per bubble: ~100 individually
// filtered layers exhaust the software rasterizer during parallel renders
// and whole regions of the frame come out unpainted.
type Band = "far" | "mid" | "front";
const bandOf = (b: Bubble): Band => (b.i === 0 ? "mid" : b.z > 0.93 ? "front" : b.z < 0.5 ? "far" : "mid");

const renderBubbles = (t: number, implode: number, agitation: number, band: Band) =>
  BUBBLES.map((b) => {
        if (bandOf(b) !== band) return null;
        const age = t - b.spawn;
        if (age < 0) return null;
        const appear = ease.outBack(clamp(age / 14));
        const scale = 0.45 + b.z * 0.8;
        const imp = ease.inExpo(clamp(implode * (1 + (1 - b.z) * 0.3)));
        const x = lerp(b.x, 960, imp);
        const y = lerp(b.y, 540, imp);
        const jitter = agitation * Math.sin(t * 1.7 + b.i) * 3;
        return (
          <div
            key={b.i}
            style={{
              position: "absolute",
              left: x,
              top: y,
              transform: `translate(-50%,-50%) scale(${scale * (1 - imp)}) rotate(${imp * 180 * (b.i % 2 ? 1 : -1)}deg)`,
              opacity: 0.35 + b.z * 0.65,
              zIndex: Math.round(b.z * 100),
            }}
          >
            <BubbleCard b={b} appear={appear} jitter={jitter} />
          </div>
        );
  });

export const unreadCount = (t: number) => {
  let n = 0;
  for (const b of BUBBLES) if (t >= b.spawn) n += b.unread;
  return n;
};
