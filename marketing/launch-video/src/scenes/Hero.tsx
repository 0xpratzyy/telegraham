import React from "react";
import { AbsoluteFill, Img, random, spring, staticFile, useCurrentFrame, useVideoConfig } from "remotion";
import { Camera } from "../fx/Camera";
import { Flash, LightStreak } from "../fx/Overlays";
import { SplitText } from "../fx/SplitText";
import { clamp, ease, lerp, pulse, prog } from "../fx/easing";
import { C, FONT } from "../theme";
import { BEAT } from "../timeline";

const MASCOT = 640;

/** Glint travelling across both sunglasses lenses. */
const Glint: React.FC<{ p: number }> = ({ p }) => {
  if (p <= 0 || p >= 1) return null;
  const x = lerp(-40, 140, p);
  return (
    <svg viewBox="0 0 100 100" style={{ position: "absolute", inset: 0 }} width={MASCOT} height={MASCOT}>
      <defs>
        <clipPath id="lenses">
          <ellipse cx="34.5" cy="34.8" rx="17.5" ry="10.5" />
          <ellipse cx="69.8" cy="34.8" rx="17.5" ry="10.5" />
        </clipPath>
        <linearGradient id="glint" x1="0" y1="0" x2="1" y2="0">
          <stop offset="0" stopColor="white" stopOpacity="0" />
          <stop offset="0.5" stopColor="white" stopOpacity="0.95" />
          <stop offset="1" stopColor="white" stopOpacity="0" />
        </linearGradient>
      </defs>
      <g clipPath="url(#lenses)">
        <rect x={x} y="-20" width="14" height="140" fill="url(#glint)" transform={`rotate(24 ${x} 50)`} />
        <rect x={x + 18} y="-20" width="5" height="140" fill="url(#glint)" transform={`rotate(24 ${x + 18} 50)`} />
      </g>
    </svg>
  );
};

export const Hero: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const iris = ease.outExpo(clamp(frame / 26));
  const slam = spring({ frame, fps, config: { damping: 11, stiffness: 140, mass: 0.9 } });
  const moveP = prog(frame, BEAT * 4, 50, ease.snap);
  const exitP = prog(frame, 330, 30, ease.inExpo);
  const glint = clamp((frame - BEAT * 2.5) / 26);
  const beatPulse = frame > 30 ? pulse(frame, Math.floor(frame / BEAT) * BEAT, 6) : 0;

  const mascotX = lerp(0, -440, moveP);
  const mascotScale = lerp(1.7, 1, slam) * lerp(1, 0.74, moveP) * (1 + beatPulse * 0.015);

  return (
    <AbsoluteFill style={{ background: "black" }}>
      <AbsoluteFill style={{ clipPath: `circle(${iris * 1250}px at 50% 50%)` }}>
        <Camera id="hero" zoom={1 + exitP * 1.8 + frame * 0.0003} shake={pulse(frame, 0, 10) * 1.2} y={exitP * -80}>
          <AbsoluteFill
            style={{
              background: `radial-gradient(circle at ${50 + mascotX / 40}% 50%, #2B7BFF 0%, ${C.mascotBlue} 30%, #0634A8 62%, #030A24 100%)`,
            }}
          />
          <AbsoluteFill
            style={{
              background: `repeating-conic-gradient(from ${frame * 0.4}deg at ${50 + mascotX / 19.2}% 50%, rgba(255,255,255,0.09) 0deg 5deg, rgba(255,255,255,0) 5deg 15deg)`,
              maskImage: "radial-gradient(circle, black 10%, transparent 70%)",
              WebkitMaskImage: "radial-gradient(circle, black 10%, transparent 70%)",
            }}
          />
          {Array.from({ length: 40 }, (_, i) => {
            const r = (k: string) => random(`hp${i}${k}`);
            const y = ((r("y") * 1200 - frame * (0.6 + r("s") * 1.6)) % 1200 + 1200) % 1200 - 60;
            const s = 3 + r("r") * 9;
            return (
              <div
                key={i}
                style={{
                  position: "absolute",
                  left: r("x") * 1920,
                  top: y,
                  width: s,
                  height: s,
                  borderRadius: s,
                  background: i % 3 ? "rgba(255,255,255,0.5)" : C.teal,
                  filter: `blur(${r("b") * 3}px)`,
                  opacity: 0.2 + r("o") * 0.6,
                }}
              />
            );
          })}
          {[0, 8, 16].map((d, i) => {
            const p = clamp((frame - d) / 50);
            if (p <= 0 || p >= 1) return null;
            return (
              <div
                key={i}
                style={{
                  position: "absolute",
                  left: 960,
                  top: 540,
                  width: ease.outCubic(p) * 2200,
                  height: ease.outCubic(p) * 2200,
                  borderRadius: "50%",
                  border: `${2 + (1 - p) * 18}px solid rgba(255,255,255,${0.75 * (1 - p)})`,
                  transform: "translate(-50%,-50%)",
                }}
              />
            );
          })}
          <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
            <div
              style={{
                width: MASCOT,
                height: MASCOT,
                position: "relative",
                transform: `translateX(${mascotX}px) scale(${mascotScale}) rotate(${(1 - slam) * -10}deg)`,
                borderRadius: MASCOT * 0.24,
                overflow: "hidden",
                boxShadow: `0 60px 120px rgba(0,0,0,0.5), 0 0 0 ${2 + beatPulse * 6}px rgba(255,255,255,${0.2 + beatPulse * 0.3}), 0 0 160px rgba(63,224,197,${0.2 + beatPulse * 0.25})`,
              }}
            >
              <Img src={staticFile("img/pidgy-mascot.png")} style={{ width: MASCOT, height: MASCOT, display: "block" }} />
              <Glint p={glint} />
            </div>
          </AbsoluteFill>
          <AbsoluteFill style={{ justifyContent: "center", paddingLeft: 900 }}>
            <div
              style={{
                fontFamily: FONT.display,
                fontWeight: 500,
                fontSize: 330,
                lineHeight: 0.9,
                letterSpacing: -12,
                color: "white",
                textShadow: "0 30px 80px rgba(0,0,40,0.5)",
              }}
            >
              <SplitText text="Pidgy" start={BEAT * 4.5} stagger={4} dur={30} />
            </div>
            <div
              style={{
                display: "flex",
                gap: 16,
                alignItems: "center",
                marginTop: 34,
                marginLeft: 14,
                fontFamily: FONT.mono,
                fontSize: 24,
                letterSpacing: 7,
                color: "rgba(255,255,255,0.85)",
                opacity: prog(frame, BEAT * 6, 24),
                transform: `translateY(${(1 - prog(frame, BEAT * 6, 24)) * 20}px)`,
              }}
            >
              <span style={{ width: 60 * prog(frame, BEAT * 6, 40), height: 2, background: C.teal, display: "inline-block" }} />
              NOW ON MACOS
            </div>
          </AbsoluteFill>
          <LightStreak y={540} intensity={pulse(frame, 0, 14) + pulse(frame, BEAT * 4.5, 10) * 0.6} color={C.teal} />
        </Camera>
      </AbsoluteFill>
      <Flash amount={pulse(frame, 0, 6)} />
      <Flash amount={exitP * 0.9} color="black" />
    </AbsoluteFill>
  );
};
