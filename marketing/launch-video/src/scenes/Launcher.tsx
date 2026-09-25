import React from "react";
import { AbsoluteFill, spring, useCurrentFrame, useVideoConfig } from "remotion";
import { LauncherPanel, PANEL_H, PANEL_W } from "../app/LauncherPanel";
import { clamp, ease, lerp, pulse } from "../fx/easing";
import { A, F } from "../app/tokens";
import { Line } from "../ui/Type";
import { FIND_QUERY, FIND_RESULT, HOTKEY, PREP_QUERY, PREP_RESULT, SCENES, findCharFrame, prepCharFrame, s } from "../timeline";

// Covers the "find" and "prep" beats: the ⌘⇧T launcher stays on screen and
// is asked a second question.
const T0 = SCENES.find.from;
const L = (abs: number) => abs - T0;
const PREP = L(SCENES.prep.from);
const END = L(SCENES.prep.from + SCENES.prep.dur);
const CY = 596;

const Key: React.FC<{ label: string; down: number }> = ({ label, down }) => (
  <div
    style={{
      width: 110,
      height: 110,
      borderRadius: 22,
      background: "linear-gradient(#474747, #383838)",
      border: `1px solid ${A.border3}`,
      boxShadow: `0 ${10 - down * 7}px 0 #222, 0 ${24 - down * 14}px 40px rgba(0,0,0,0.35)`,
      transform: `translateY(${down * 7}px)`,
      display: "flex",
      alignItems: "center",
      justifyContent: "center",
      fontFamily: F.ui,
      fontSize: 50,
      color: A.fg1,
    }}
  >
    {label}
  </div>
);

const typedCount = (abs: number, q: string, fn: (i: number) => number) => q.split("").filter((_, i) => abs >= fn(i)).length;

export const Launcher: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const abs = frame + T0;
  const inPrep = frame >= PREP;

  const keys = Math.min(clamp(frame / 10), 1 - clamp((frame - s(0.8)) / 12));
  const panel = spring({ frame: frame - s(0.8), fps, config: { damping: 18, stiffness: 130 } });
  const out = ease.inOutCubic(clamp((frame - (END - s(0.55))) / s(0.5)));
  const push = ease.inOutCubic(clamp((frame - L(FIND_RESULT)) / s(1.2))) * (1 - ease.inOutCubic(clamp((frame - (PREP - s(0.5))) / s(0.5))));
  const push2 = ease.inOutCubic(clamp((frame - L(PREP_RESULT)) / s(1.2)));
  const S = 1.6 + 0.14 * Math.max(push, push2);

  const typed = inPrep ? typedCount(abs, PREP_QUERY, prepCharFrame) : typedCount(abs, FIND_QUERY, findCharFrame);
  const clearing = !inPrep && frame > PREP - s(0.3);
  const mode = inPrep ? (typed > 0 ? "answer" : "idle") : abs >= FIND_RESULT && !clearing ? "wallet" : "idle";
  const resultT = inPrep ? frame - L(PREP_RESULT) : frame - L(FIND_RESULT);
  const typedEnd = inPrep ? L(prepCharFrame(PREP_QUERY.length - 1)) : 0;
  const thinking = inPrep ? clamp((frame - typedEnd) / (L(PREP_RESULT) - typedEnd)) : 0;
  const caret = Math.floor(frame / 16) % 2 === 0 || (typed > 0 && typed < (inPrep ? PREP_QUERY.length : FIND_QUERY.length));

  return (
    <AbsoluteFill>
      <div style={{ position: "absolute", left: 0, right: 0, top: 58 }}>
        <Line text="Find any message." inAt={s(0.1)} outAt={PREP - s(0.45)} size={64} />
      </div>
      <div style={{ position: "absolute", left: 0, right: 0, top: 58 }}>
        <Line text="Prep before you reply." inAt={PREP + s(0.05)} outAt={END - s(0.55)} size={64} />
      </div>

      {keys > 0.01 && (
        <div style={{ position: "absolute", left: 0, right: 0, top: 480, display: "flex", justifyContent: "center", gap: 26, opacity: keys, transform: `scale(${0.9 + keys * 0.1})` }}>
          {["⌘", "⇧", "T"].map((k, i) => (
            <Key key={k} label={k} down={abs >= HOTKEY[i] ? clamp(pulse(abs, HOTKEY[i], 12) * 1.3) : 0} />
          ))}
        </div>
      )}

      <div
        style={{
          position: "absolute",
          left: 960 - (PANEL_W * S) / 2,
          top: CY - (PANEL_H * S) / 2 + (1 - panel) * 40 - Math.max(push, push2) * 30,
          transformOrigin: "0 0",
          transform: `scale(${S * lerp(0.94, 1, clamp(panel))})`,
          opacity: clamp(panel * 1.5) * (1 - out),
          filter: out > 0 ? `blur(${out * 8}px)` : undefined,
        }}
      >
        <LauncherPanel
          query={inPrep ? PREP_QUERY : FIND_QUERY}
          typed={clearing ? 0 : typed}
          caret={caret}
          mode={mode}
          resultT={resultT}
          thinking={thinking}
        />
      </div>

      <div style={{ position: "absolute", left: 0, right: 0, bottom: 34 }}>
        <Line text="The message, not the chat." inAt={L(FIND_RESULT) + s(0.35)} outAt={PREP - s(0.45)} size={40} />
      </div>
      <div style={{ position: "absolute", left: 0, right: 0, bottom: 34 }}>
        <Line text="One bounded summary. 10 seconds." inAt={L(PREP_RESULT) + s(0.6)} outAt={END - s(0.55)} size={40} />
      </div>
    </AbsoluteFill>
  );
};
