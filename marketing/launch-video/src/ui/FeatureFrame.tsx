import React from "react";
import { AbsoluteFill, useCurrentFrame } from "remotion";
import { Aurora, GridFloor } from "../fx/Overlays";
import { SplitText } from "../fx/SplitText";
import { Whip } from "../fx/Whip";
import { clamp, ease, prog } from "../fx/easing";
import { C, FONT } from "../theme";

/**
 * Shared layout for the four feature beats: numbered eyebrow + serif headline
 * on the left, a tilted 3D product panel on the right, whip transitions at
 * both ends.
 */
export const FeatureFrame: React.FC<{
  id: string;
  dur: number;
  index: string;
  eyebrow: string;
  title: string[];
  sub: string;
  aurora: string[];
  children: React.ReactNode;
  panelWidth?: number;
}> = ({ id, dur, index, eyebrow, title, sub, aurora, children, panelWidth = 1040 }) => {
  const frame = useCurrentFrame();
  const tilt = 1 - prog(frame, 6, 80, ease.snap);
  const drift = frame / dur;
  const exit = clamp((frame - (dur - 24)) / 24);
  return (
    <AbsoluteFill style={{ background: C.void }}>
      <Aurora colors={aurora} opacity={0.55} seed={id} />
      <GridFloor />
      <Whip id={id} dur={dur}>
        <AbsoluteFill style={{ padding: "0 70px 0 100px", flexDirection: "row", alignItems: "center" }}>
          <div style={{ width: 580, flex: "none", transform: `translateX(${-drift * 30}px)` }}>
            <div
              style={{
                fontFamily: FONT.mono,
                fontSize: 20,
                color: C.accentFg,
                letterSpacing: 4,
                display: "flex",
                gap: 18,
                alignItems: "center",
                opacity: prog(frame, 10, 20),
              }}
            >
              <span style={{ color: "white" }}>{index}</span>
              <span
                style={{
                  height: 1,
                  width: 80 * prog(frame, 14, 40),
                  background: C.accent,
                  display: "inline-block",
                }}
              />
              <span>{eyebrow}</span>
            </div>
            <div
              style={{
                fontFamily: FONT.display,
                fontWeight: 500,
                fontSize: 96,
                lineHeight: 1.0,
                letterSpacing: -3,
                color: "white",
                marginTop: 28,
              }}
            >
              {title.map((line, i) => (
                <div key={i}>
                  <SplitText text={line} start={16 + i * 8} by="word" stagger={5} dur={34} exitAt={dur - 26} />
                </div>
              ))}
            </div>
            <div
              style={{
                fontFamily: FONT.ui,
                fontSize: 27,
                lineHeight: 1.45,
                color: C.fg2,
                marginTop: 34,
                maxWidth: 560,
                opacity: prog(frame, 40, 30) * (1 - exit),
                transform: `translateY(${(1 - prog(frame, 40, 30)) * 24}px)`,
              }}
            >
              {sub}
            </div>
          </div>
          <div style={{ flex: 1, display: "flex", justifyContent: "center", perspective: 2200 }}>
            <div
              style={{
                width: panelWidth,
                transform: `translateX(${-drift * 60 + 30}px) rotateY(${-16 * tilt - 5 + drift * 4}deg) rotateX(${6 * tilt + 3}deg) translateZ(${-200 * tilt}px) scale(1.16)`,
                transformStyle: "preserve-3d",
              }}
            >
              {children}
            </div>
          </div>
        </AbsoluteFill>
      </Whip>
    </AbsoluteFill>
  );
};
