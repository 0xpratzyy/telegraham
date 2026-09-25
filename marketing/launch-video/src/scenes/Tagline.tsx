import React from "react";
import { AbsoluteFill, useCurrentFrame } from "remotion";
import { Camera } from "../fx/Camera";
import { Aurora } from "../fx/Overlays";
import { SplitText } from "../fx/SplitText";
import { clamp, ease, lerp, pulse, prog } from "../fx/easing";
import { C, CHANNEL, FONT } from "../theme";
import { Glyph } from "../ui/Glyph";
import { BEAT, CHANNEL_ORDER, SCENES } from "../timeline";

export const Tagline: React.FC = () => {
  const frame = useCurrentFrame();
  const dur = SCENES.tagline.dur;
  const underline = prog(frame, BEAT * 2 + 18, 40, ease.inOutCubic);
  const out = prog(frame, dur - 14, 14, ease.inExpo);

  return (
    <AbsoluteFill style={{ background: C.void }}>
      <Aurora colors={["rgba(79,127,220,0.55)", "rgba(106,61,232,0.4)", "rgba(63,224,197,0.25)"]} opacity={0.7} seed="tag" />
      <Camera id="tag" zoom={1.02 + frame * 0.0004 + pulse(frame, 0, 8) * 0.04 + pulse(frame, BEAT * 2, 8) * 0.03} x={out * -700} blurX={out * 60}>
        <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", perspective: 1600 }}>
          {CHANNEL_ORDER.map((id, i) => {
            const snapAt = BEAT * (4.5 + i * 0.5);
            const snap = ease.snap(clamp((frame - snapAt) / 20));
            const a = frame * 0.035 + (i * Math.PI) / 2;
            const ox = Math.cos(a) * 760;
            const oy = Math.sin(a) * 120 - 20;
            const oz = Math.sin(a) * 300;
            const tx = (i - 1.5) * 250;
            const ty = 300;
            const x = lerp(ox, tx, snap);
            const y = lerp(oy, ty, snap);
            const z = lerp(oz, 0, snap);
            const behind = snap < 0.5 && Math.sin(a) < 0;
            const s = 1 + pulse(frame, snapAt, 8) * 0.25;
            return (
              <div
                key={id}
                style={{
                  position: "absolute",
                  left: 960,
                  top: 540,
                  transform: `translate(-50%,-50%) translate3d(${x}px, ${y}px, ${z}px) scale(${s})`,
                  zIndex: behind ? 0 : 3,
                  opacity: prog(frame, i * 4, 20) * (behind ? 0.45 : 1),
                  filter: behind ? "blur(3px)" : undefined,
                  display: "flex",
                  flexDirection: "column",
                  alignItems: "center",
                  gap: 14,
                }}
              >
                <Glyph
                  id={id}
                  size={lerp(110, 84, snap)}
                  tile
                  style={{ boxShadow: `0 20px 50px rgba(0,0,0,0.5), 0 0 ${40 * pulse(frame, snapAt, 10)}px ${CHANNEL[id].tint}` }}
                />
                <div
                  style={{
                    fontFamily: FONT.ui,
                    fontSize: 24,
                    fontWeight: 600,
                    color: C.fg1,
                    opacity: snap,
                    transform: `translateY(${(1 - snap) * 10}px)`,
                  }}
                >
                  {CHANNEL[id].name}
                </div>
              </div>
            );
          })}
          <div
            style={{
              zIndex: 2,
              position: "relative",
              textAlign: "center",
              fontFamily: FONT.display,
              fontWeight: 500,
              color: "white",
              letterSpacing: -5,
              lineHeight: 1.02,
              marginTop: -150,
            }}
          >
            <div style={{ fontSize: 170 }}>
              <SplitText text="Every chat." start={0} stagger={2} dur={26} />
            </div>
            <div style={{ fontSize: 132, position: "relative", display: "inline-block" }}>
              <SplitText text="One " start={BEAT * 2} stagger={2} dur={26} />
              <span style={{ position: "relative", display: "inline-block" }}>
                <SplitText
                  text="command center."
                  start={BEAT * 2 + 6}
                  stagger={2}
                  dur={26}
                  style={{ fontStyle: "italic", color: C.accentFg }}
                />
                <div
                  style={{
                    position: "absolute",
                    left: 6,
                    right: 40,
                    bottom: -6,
                    height: 9,
                    borderRadius: 5,
                    background: `linear-gradient(90deg, ${C.accent}, ${C.accentFg})`,
                    transform: `scaleX(${underline})`,
                    transformOrigin: "0% 50%",
                    boxShadow: `0 0 24px ${C.accentRing}`,
                  }}
                />
              </span>
            </div>
          </div>
        </AbsoluteFill>
      </Camera>
    </AbsoluteFill>
  );
};
