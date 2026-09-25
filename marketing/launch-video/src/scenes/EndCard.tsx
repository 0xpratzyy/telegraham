import React from "react";
import { AbsoluteFill, random, spring, useCurrentFrame, useVideoConfig } from "remotion";
import { Flash, LightStreak, MascotImg } from "../fx/Overlays";
import { SplitText } from "../fx/SplitText";
import { clamp, ease, pulse, prog } from "../fx/easing";
import { C, CHANNEL, FONT } from "../theme";
import { Glyph } from "../ui/Glyph";
import { BEAT, CHANNEL_ORDER, SCENES } from "../timeline";

export const EndCard: React.FC<{ cta: string; url: string }> = ({ cta, url }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const dur = SCENES.end.dur;
  const m = spring({ frame, fps, config: { damping: 13, stiffness: 120 } });
  const fadeOut = prog(frame, dur - 26, 26, ease.inOutCubic);
  const ctaP = ease.outBack(clamp((frame - BEAT * 2.2) / 18));

  return (
    <AbsoluteFill style={{ background: `radial-gradient(circle at 50% 42%, #10307a 0%, #071233 45%, ${C.void} 100%)` }}>
      {Array.from({ length: 50 }, (_, i) => {
        const r = (k: string) => random(`ep${i}${k}`);
        const a = r("a") * Math.PI * 2;
        const d = (r("d") * 300 + frame * (1 + r("s") * 4)) % 1100;
        const s = 2 + r("z") * 5;
        return (
          <div
            key={i}
            style={{
              position: "absolute",
              left: 960 + Math.cos(a) * d,
              top: 420 + Math.sin(a) * d * 0.6,
              width: s,
              height: s,
              borderRadius: s,
              background: i % 4 ? "rgba(145,172,232,0.7)" : C.teal,
              opacity: Math.min(1, d / 200) * 0.6,
            }}
          />
        );
      })}
      {[0, 10].map((d, i) => {
        const p = clamp((frame - d) / 60);
        if (p <= 0 || p >= 1) return null;
        return (
          <div
            key={i}
            style={{
              position: "absolute",
              left: 960,
              top: 400,
              width: ease.outCubic(p) * 2400,
              height: ease.outCubic(p) * 2400,
              borderRadius: "50%",
              border: `${2 + (1 - p) * 14}px solid rgba(255,255,255,${0.6 * (1 - p)})`,
              transform: "translate(-50%,-50%)",
            }}
          />
        );
      })}
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", transform: `scale(${1 + frame * 0.0003})` }}>
        <div style={{ display: "flex", alignItems: "center", gap: 56, marginTop: -120 }}>
          <div
            style={{
              transform: `scale(${0.4 + m * 0.6}) rotate(${(1 - m) * -14}deg)`,
              borderRadius: 72,
              boxShadow: `0 40px 100px rgba(0,0,0,0.55), 0 0 ${120 + pulse(frame, 0, 20) * 200}px rgba(63,224,197,0.35)`,
            }}
          >
            <MascotImg size={280} radius={0.24} />
          </div>
          <div style={{ fontFamily: FONT.display, fontWeight: 500, fontSize: 250, letterSpacing: -10, color: "white", lineHeight: 0.9 }}>
            <SplitText text="Pidgy" start={6} stagger={3} dur={28} />
          </div>
        </div>
        <div style={{ fontFamily: FONT.ui, fontSize: 38, color: C.fg1, marginTop: 44, opacity: prog(frame, 26, 22), transform: `translateY(${(1 - prog(frame, 26, 22)) * 16}px)` }}>
          The command center for every chat.
        </div>
        <div style={{ display: "flex", gap: 34, marginTop: 34 }}>
          {CHANNEL_ORDER.map((id, i) => {
            const p = ease.outBack(clamp((frame - 40 - i * 4) / 16));
            return (
              <div key={id} style={{ display: "flex", alignItems: "center", gap: 12, transform: `scale(${Math.max(0, p)})`, fontFamily: FONT.ui, fontSize: 24, color: C.fg2, fontWeight: 600 }}>
                <Glyph id={id} size={50} tile />
                {CHANNEL[id].name}
              </div>
            );
          })}
        </div>
        <div
          style={{
            marginTop: 50,
            transform: `scale(${Math.max(0, ctaP)})`,
            background: "white",
            color: "#0A0B0E",
            fontFamily: FONT.ui,
            fontWeight: 700,
            fontSize: 30,
            padding: "20px 42px",
            borderRadius: 999,
            boxShadow: `0 20px 60px rgba(79,127,220,0.5), 0 0 0 ${pulse(frame, BEAT * 3, 12) * 14}px rgba(255,255,255,0.25)`,
          }}
        >
          {cta}
        </div>
        {url && (
          <div style={{ marginTop: 22, fontFamily: FONT.mono, fontSize: 24, letterSpacing: 2, color: C.fg2, opacity: prog(frame, BEAT * 2.6, 20) }}>{url}</div>
        )}
      </AbsoluteFill>
      <LightStreak y={400} intensity={pulse(frame, 0, 16)} color={C.accentFg} />
      <Flash amount={pulse(frame, 0, 7)} />
      <Flash amount={fadeOut} color="black" />
    </AbsoluteFill>
  );
};
