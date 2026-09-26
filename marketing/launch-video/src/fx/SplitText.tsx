import React from "react";
import { useCurrentFrame } from "remotion";
import { clamp, ease } from "./easing";

type Mode = "rise" | "blur" | "drop" | "scale";

/**
 * Per-letter (or per-word) staggered reveal. Each unit animates inside its own
 * overflow mask so "rise" reads as a clean masked slide-up.
 */
export const SplitText: React.FC<{
  text: string;
  start: number;
  stagger?: number;
  dur?: number;
  by?: "char" | "word";
  mode?: Mode;
  style?: React.CSSProperties;
  unitStyle?: (i: number, p: number) => React.CSSProperties;
  exitAt?: number;
  exitDur?: number;
}> = ({ text, start, stagger = 2, dur = 26, by = "char", mode = "rise", style, unitStyle, exitAt, exitDur = 14 }) => {
  const frame = useCurrentFrame();
  const units = by === "char" ? Array.from(text) : text.split(/(\s+)/);
  let idx = 0;
  return (
    <span style={{ display: "inline-block", whiteSpace: "pre", ...style }}>
      {units.map((u, k) => {
        if (/^\s+$/.test(u)) return <span key={k}>{u}</span>;
        const i = idx++;
        const p = ease.snap(clamp((frame - start - i * stagger) / dur));
        const x = exitAt !== undefined ? ease.inCubic(clamp((frame - exitAt - i * (stagger * 0.5)) / exitDur)) : 0;
        let tf = "";
        let filter = "";
        let opacity = 1;
        if (mode === "rise") {
          tf = `translateY(${(1 - p) * 110 - x * 110}%) rotate(${(1 - p) * 8}deg)`;
        } else if (mode === "blur") {
          tf = `translateY(${(1 - p) * 30}px) scale(${1 + (1 - p) * 0.4})`;
          filter = `blur(${(1 - p) * 18 + x * 18}px)`;
          opacity = p * (1 - x);
        } else if (mode === "drop") {
          tf = `translateY(${(1 - ease.outBack(clamp((frame - start - i * stagger) / dur))) * -140}%)`;
          opacity = clamp(p * 3) * (1 - x);
        } else {
          const s = ease.outBack(clamp((frame - start - i * stagger) / dur));
          tf = `scale(${Math.max(0, s) * (1 - x)})`;
          opacity = clamp(p * 4);
        }
        return (
          <span
            key={k}
            style={{
              display: "inline-block",
              overflow: mode === "rise" ? "hidden" : "visible",
              verticalAlign: "bottom",
              paddingBottom: mode === "rise" ? "0.08em" : 0,
              marginBottom: mode === "rise" ? "-0.08em" : 0,
            }}
          >
            <span
              style={{
                display: "inline-block",
                transform: tf,
                filter: filter || undefined,
                opacity,
                transformOrigin: "50% 100%",
                ...(unitStyle ? unitStyle(i, p) : {}),
              }}
            >
              {u}
            </span>
          </span>
        );
      })}
    </span>
  );
};
