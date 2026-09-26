import React from "react";
import { AbsoluteFill, useCurrentFrame } from "remotion";
import { Camera } from "../fx/Camera";
import { MascotImg } from "../fx/Overlays";
import { clamp, ease, pulse, rnd } from "../fx/easing";
import { C, CHANNEL, FONT } from "../theme";
import { Glyph } from "../ui/Glyph";
import { Chip } from "../ui/Window";
import { BEAT, CHANNEL_ORDER, RAPID_WORDS } from "../timeline";

const PALETTE: { bg: string; fg: string }[] = [
  { bg: C.accent, fg: "white" },
  { bg: "#F4F4F2", fg: "#0A0B0E" },
  { bg: C.void, fg: C.accentFg },
  { bg: C.mascotBlue, fg: "white" },
];

const Fragment: React.FC<{ i: number; beatIdx: number }> = ({ i, beatIdx }) => {
  const seed = `${beatIdx}-${i}`;
  const x = rnd(`fx${seed}`, 80, 1600);
  const top = rnd(`fb${seed}`) < 0.5;
  const y = top ? rnd(`fy${seed}`, 50, 300) : rnd(`fy${seed}`, 760, 980);
  const kind = Math.floor(rnd(`fk${seed}`, 0, 3));
  const ch = CHANNEL_ORDER[Math.floor(rnd(`fc${seed}`, 0, 4))];
  const rot = rnd(`fr${seed}`, -12, 12);
  return (
    <div style={{ position: "absolute", left: x, top: y, transform: `rotate(${rot}deg)`, opacity: 0.55 }}>
      {kind === 0 && <Glyph id={ch} size={80} tile />}
      {kind === 1 && (
        <Chip style={{ fontSize: 24, padding: "10px 18px" }} color="white" bg="rgba(0,0,0,0.35)">
          <Glyph id={ch} size={26} tile /> {CHANNEL[ch].name}
        </Chip>
      )}
      {kind === 2 && (
        <div style={{ fontFamily: FONT.mono, fontSize: 26, color: "white", background: "rgba(0,0,0,0.35)", padding: "8px 14px", borderRadius: 8 }}>
          0x7a3F…c91E
        </div>
      )}
    </div>
  );
};

export const Rapid: React.FC = () => {
  const frame = useCurrentFrame();
  const idx = Math.min(RAPID_WORDS.length - 1, Math.floor(frame / BEAT));
  const local = frame - idx * BEAT;
  const w = RAPID_WORDS[idx];
  const punch = ease.outExpo(clamp(local / 10));
  const scale = 1.35 - 0.35 * punch + pulse(frame, idx * BEAT + BEAT / 2, 5) * 0.02;
  const rot = (idx % 2 ? 1 : -1) * (1 - punch) * 6;

  let bg: string;
  let fg: string;
  if (w.channel) {
    bg = CHANNEL[w.channel].color;
    fg = "white";
  } else if (w.stutter) {
    const prev = PALETTE[(idx - 1) % PALETTE.length];
    bg = prev.fg === "white" ? "#F4F4F2" : C.void;
    fg = prev.fg === "white" ? "#0A0B0E" : "white";
  } else {
    const p = PALETTE[idx % PALETTE.length];
    bg = p.bg;
    fg = p.fg;
  }
  if (w.text === "One Pidgy." && !w.stutter) {
    bg = C.mascotBlue;
    fg = "white";
  }

  const split = w.stutter ? (1 - punch) * 40 + 6 : (1 - punch) * 18;
  const slice = w.stutter && local < 12 ? (local % 4 < 2 ? 50 : -50) : 0;

  const word = (color: string, dx: number, blend?: "screen" | "multiply") => (
    <AbsoluteFill
      style={{
        alignItems: "center",
        justifyContent: "center",
        transform: `translateX(${dx}px)`,
        mixBlendMode: blend,
      }}
    >
      <div
        style={{
          fontFamily: w.channel ? FONT.ui : FONT.display,
          fontWeight: w.channel ? 800 : 500,
          fontStyle: w.channel ? "normal" : "italic",
          fontSize: w.channel ? 190 : 280,
          letterSpacing: w.channel ? -6 : -10,
          color,
          display: "flex",
          alignItems: "center",
          gap: 50,
          lineHeight: 1,
        }}
      >
        {w.channel && <Glyph id={w.channel} size={230} tile style={{ boxShadow: "0 30px 80px rgba(0,0,0,0.35)" }} />}
        {w.text === "One Pidgy." && <MascotImg size={230} radius={0.24} style={{ boxShadow: "0 30px 80px rgba(0,0,0,0.35)" }} />}
        {w.text}
      </div>
    </AbsoluteFill>
  );

  const light = bg === "#F4F4F2";
  return (
    <AbsoluteFill style={{ background: bg }}>
      {local < 20 && [0, 1, 2, 3, 4].map((i) => <Fragment key={i} i={i} beatIdx={idx} />)}
      <Camera id={`rapid${idx}`} zoom={scale} rot={rot} shake={pulse(frame, idx * BEAT, 6) * 0.6}>
        {!w.channel && (
          <>
            {word(light ? "#00d0ff" : "#ff2a55", -split, light ? "multiply" : "screen")}
            {word(light ? "#ff2a55" : "#2af0ff", split, light ? "multiply" : "screen")}
          </>
        )}
        <AbsoluteFill style={{ clipPath: slice ? "inset(0 0 50% 0)" : undefined, transform: `translateX(${slice}px)` }}>{word(fg, 0)}</AbsoluteFill>
        {slice !== 0 && <AbsoluteFill style={{ clipPath: "inset(50% 0 0 0)", transform: `translateX(${-slice}px)` }}>{word(fg, 0)}</AbsoluteFill>}
      </Camera>
      <AbsoluteFill style={{ background: "white", opacity: pulse(frame, idx * BEAT, 3) * 0.35 }} />
    </AbsoluteFill>
  );
};
