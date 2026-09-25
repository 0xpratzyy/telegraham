import React from "react";
import { AbsoluteFill, spring, useCurrentFrame, useVideoConfig } from "remotion";
import { clamp, ease } from "../fx/easing";
import { AppIcon } from "../fx/Overlays";
import { env } from "../fx/track";
import { C, FONT } from "../theme";
import { Line } from "../ui/Type";
import { s } from "../timeline";

const LEFT: React.CSSProperties = { textAlign: "left" };

// Left column over open sky; the tree and the kid napping under it keep the
// right half of the frame.
export const End: React.FC<{ cta: string; url: string }> = ({ cta, url }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const lock = s(3.0);
  const icon = spring({ frame: frame - lock, fps, config: { damping: 16, stiffness: 90 } });
  const name = env(frame, lock + 8, 1e9, 30);
  const btn = env(frame, lock + s(0.8), 1e9, 26);
  const fade = ease.inOutCubic(clamp((frame - s(5.4)) / s(0.6)));

  return (
    <AbsoluteFill>
      <AbsoluteFill style={{ justifyContent: "center", paddingLeft: 150, paddingBottom: 180 }}>
        <Line text="The system you've been" inAt={s(0.05)} outAt={s(2.7)} size={92} style={LEFT} />
        <Line text="pretending you have." inAt={s(0.35)} outAt={s(2.7)} size={92} italic style={LEFT} />
      </AbsoluteFill>
      <AbsoluteFill style={{ justifyContent: "center", paddingLeft: 150, paddingBottom: 120 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 34 }}>
          <div style={{ opacity: clamp(icon * 2), transform: `translateY(${(1 - icon) * 30}px) scale(${0.9 + icon * 0.1})` }}>
            <AppIcon size={150} />
          </div>
          <div
            style={{
              fontFamily: FONT.ui,
              fontWeight: 700,
              fontSize: 132,
              letterSpacing: -4,
              lineHeight: 1,
              color: "white",
              opacity: name,
              filter: `blur(${(1 - name) * 10}px)`,
              transform: `translateX(${(1 - name) * -16}px)`,
              textShadow: "0 4px 40px rgba(10,30,80,0.35)",
            }}
          >
            Pidgy
          </div>
        </div>
        <Line text="Every message finds its way home." inAt={lock + s(0.4)} size={60} style={{ ...LEFT, marginTop: 30 }} />
        <div style={{ marginTop: 40, opacity: btn, transform: `translateY(${(1 - btn) * 16}px)`, display: "flex", alignItems: "center", gap: 28 }}>
          <div
            style={{
              background: C.cta,
              color: "white",
              fontFamily: FONT.ui,
              fontWeight: 600,
              fontSize: 30,
              padding: "18px 40px",
              borderRadius: 999,
              boxShadow: "0 10px 30px rgba(29,111,243,0.45), inset 0 1px 0 rgba(255,255,255,0.25)",
            }}
          >
            {cta}
          </div>
          {url && <div style={{ fontFamily: FONT.mono, fontSize: 26, letterSpacing: 1, color: "rgba(255,255,255,0.9)", textShadow: "0 2px 16px rgba(0,0,0,0.3)" }}>{url}</div>}
        </div>
      </AbsoluteFill>
      <AbsoluteFill style={{ background: "black", opacity: fade }} />
    </AbsoluteFill>
  );
};
