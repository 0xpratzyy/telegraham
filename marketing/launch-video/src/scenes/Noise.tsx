import React from "react";
import { AbsoluteFill, useCurrentFrame } from "remotion";
import { Camera } from "../fx/Camera";
import { Aurora, Flash } from "../fx/Overlays";
import { clamp, ease, pulse, prog } from "../fx/easing";
import { C, FONT } from "../theme";
import { BEAT, SCENES } from "../timeline";
import { NoiseField, unreadCount } from "./NoiseField";

export const Noise: React.FC = () => {
  const frame = useCurrentFrame();
  const dur = SCENES.noise.dur;
  const build = clamp((frame - 90) / (dur - 90));
  const beatKick = frame >= 60 ? pulse(frame, Math.floor(frame / BEAT) * BEAT, 7) : 0;
  const zoom = 1 + ease.inCubic(frame / dur) * 0.14 + beatKick * 0.012;
  const count = unreadCount(frame);
  const counterIn = prog(frame, 96, 24);
  const glitch = frame > dur - 10;

  return (
    <AbsoluteFill style={{ background: C.void }}>
      <Aurora colors={["rgba(214,61,67,0.35)", "rgba(79,127,220,0.35)", "rgba(37,211,102,0.18)"]} opacity={build * 0.9} speed={3} seed="noise" />
      <Camera id="noise" zoom={zoom} shake={build * build * 0.7 + beatKick * 0.2}>
        <NoiseField t={frame} layer="back" agitation={build} />
        <AbsoluteFill
          style={{
            alignItems: "center",
            justifyContent: "center",
            zIndex: 150,
            opacity: counterIn,
            transform: `scale(${0.8 + counterIn * 0.2 + beatKick * 0.03})`,
          }}
        >
          <div
            style={{
              fontFamily: FONT.ui,
              fontWeight: 800,
              fontSize: 300,
              letterSpacing: -14,
              color: "white",
              lineHeight: 1,
              fontVariantNumeric: "tabular-nums",
              textShadow: "0 20px 80px rgba(0,0,0,0.9), 0 0 60px rgba(214,61,67,0.5)",
              transform: glitch ? `translateX(${(frame % 2 ? 1 : -1) * 18}px) skewX(${(frame % 3) * 6}deg)` : undefined,
            }}
          >
            {count.toLocaleString("en-US")}
          </div>
          <div
            style={{
              fontFamily: FONT.mono,
              fontSize: 30,
              letterSpacing: 8,
              color: C.fg1,
              marginTop: 10,
              textTransform: "uppercase",
              background: "rgba(10,11,14,0.75)",
              padding: "10px 22px",
              borderRadius: 10,
            }}
          >
            unread · 4 apps · 1 of you
          </div>
        </AbsoluteFill>
        <div style={{ position: "absolute", inset: 0, zIndex: 200 }}>
          <NoiseField t={frame} layer="front" agitation={build} />
        </div>
      </Camera>
      <Flash amount={glitch ? 0.25 * (frame % 2) : 0} />
    </AbsoluteFill>
  );
};
