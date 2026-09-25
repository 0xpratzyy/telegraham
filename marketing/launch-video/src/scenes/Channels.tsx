import React from "react";
import { AbsoluteFill, useCurrentFrame } from "remotion";
import { clamp, ease } from "../fx/easing";
import { C, CHANNEL, FONT } from "../theme";
import { Glyph } from "../ui/Glyph";
import { Line } from "../ui/Type";
import { CHANNEL_AT, CHANNEL_ORDER, SCENES, s } from "../timeline";

export const Channels: React.FC = () => {
  const frame = useCurrentFrame();
  const out = s(5.4);
  return (
    <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
      <Line text="One launcher." inAt={s(0.1)} outAt={out} size={96} />
      <Line text="Every place work happens." inAt={s(0.5)} outAt={out} size={96} italic />
      <div style={{ display: "flex", gap: 22, marginTop: 64 }}>
        {CHANNEL_ORDER.map((id, i) => {
          const f = CHANNEL_AT[i] - SCENES.channels.from;
          const p = ease.snap(clamp((frame - f) / 26)) * (1 - ease.inOutCubic(clamp((frame - out - i * 2) / 18)));
          const live = CHANNEL[id].live;
          return (
            <div
              key={id}
              style={{
                display: "flex",
                alignItems: "center",
                gap: 16,
                padding: "16px 24px 16px 18px",
                borderRadius: 999,
                background: "rgba(28,28,30,0.55)",
                border: `1px solid ${live ? "rgba(91,209,139,0.35)" : C.border2}`,
                opacity: p,
                transform: `translateY(${(1 - p) * 26}px)`,
                filter: `blur(${(1 - p) * 6}px)`,
                fontFamily: FONT.ui,
              }}
            >
              <Glyph id={id} size={46} tile />
              <span style={{ fontSize: 30, fontWeight: 600, color: live ? "white" : C.fg1 }}>{CHANNEL[id].name}</span>
              <span
                style={{
                  fontSize: 14,
                  fontWeight: 700,
                  letterSpacing: 1.4,
                  padding: "5px 10px",
                  borderRadius: 7,
                  color: live ? C.success : C.fg3,
                  background: live ? "rgba(91,209,139,0.14)" : "rgba(255,255,255,0.06)",
                }}
              >
                {live ? "LIVE" : "SOON"}
              </span>
            </div>
          );
        })}
      </div>
    </AbsoluteFill>
  );
};
