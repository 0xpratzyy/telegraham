import React from "react";
import { clamp, ease, lerp } from "../fx/easing";

export type CursorKey = [frame: number, x: number, y: number];

/** macOS arrow pointer following eased keyframes, with click ripples. */
export const Cursor: React.FC<{ frame: number; keys: CursorKey[]; clicks: number[]; show: [number, number] }> = ({ frame, keys, clicks, show }) => {
  if (frame < show[0] || frame > show[1]) return null;
  let x = keys[0][1];
  let y = keys[0][2];
  for (let i = 1; i < keys.length; i++) {
    const [f0, x0, y0] = keys[i - 1];
    const [f1, x1, y1] = keys[i];
    if (frame >= f0) {
      const p = ease.inOutCubic(clamp((frame - f0) / (f1 - f0)));
      x = lerp(x0, x1, p);
      y = lerp(y0, y1, p);
    }
  }
  const press = clicks.reduce((m, c) => Math.max(m, frame >= c && frame < c + 8 ? 1 - (frame - c) / 8 : 0), 0);
  const fade = Math.min(clamp((frame - show[0]) / 8), clamp((show[1] - frame) / 8));
  return (
    <div style={{ position: "absolute", left: x, top: y, pointerEvents: "none", opacity: fade, zIndex: 50 }}>
      {clicks.map((c) => {
        const p = clamp((frame - c) / 18);
        if (frame < c || p >= 1) return null;
        return (
          <div
            key={c}
            style={{
              position: "absolute",
              left: -18,
              top: -18,
              width: 36,
              height: 36,
              borderRadius: 18,
              border: "2px solid rgba(255,255,255,0.7)",
              transform: `scale(${0.4 + p})`,
              opacity: 1 - p,
            }}
          />
        );
      })}
      <svg width="22" height="30" viewBox="0 0 22 30" style={{ transform: `scale(${1 - press * 0.12})`, transformOrigin: "0 0", filter: "drop-shadow(0 2px 3px rgba(0,0,0,0.45))" }}>
        <path d="M1.5 1.5v22.3l5.3-5 3.6 8.5 3.6-1.5-3.6-8.4h7.3z" fill="#000" stroke="#fff" strokeWidth="1.6" strokeLinejoin="round" />
      </svg>
    </div>
  );
};
