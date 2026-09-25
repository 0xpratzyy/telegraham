import React from "react";
import { useCurrentFrame } from "remotion";
import { clamp, ease, lerp, rnd } from "../fx/easing";

/** Minimal gull silhouette, wings driven by `flap` in -1..1. */
export const Bird: React.FC<{ size: number; flap: number; color?: string }> = ({ size, flap, color = "#15264A" }) => {
  const h = 16 * flap;
  return (
    <svg width={size} height={size * 0.6} viewBox="-50 -30 100 60" style={{ overflow: "visible" }}>
      <path
        d={`M -46 ${-4 - h * 0.6} Q -22 ${-10 - h} 0 4 Q 22 ${-10 - h} 46 ${-4 - h * 0.6}`}
        fill="none"
        stroke={color}
        strokeWidth={7}
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
};

/** A small flock crossing the frame left-to-right, rising gently. */
export const Flock: React.FC<{ start: number; dur: number; count: number; seed: string; y?: number }> = ({
  start,
  dur,
  count,
  seed,
  y = 420,
}) => {
  const frame = useCurrentFrame();
  const t = (frame - start) / dur;
  if (t < 0 || t > 1) return null;
  return (
    <>
      {Array.from({ length: count }, (_, i) => {
        const lag = rnd(`${seed}l${i}`, 0, 0.18);
        const p = clamp((t - lag) / (1 - lag));
        if (p <= 0 || p >= 1) return null;
        const x = lerp(-120, 2040, ease.inOutCubic(p) * 0.3 + p * 0.7);
        const yy = y + rnd(`${seed}y${i}`, -140, 120) - p * 260 + Math.sin(frame * 0.05 + i) * 8;
        const size = rnd(`${seed}s${i}`, 34, 62);
        const flap = Math.sin(frame * rnd(`${seed}f${i}`, 0.34, 0.42) + i * 1.7);
        return (
          <div key={i} style={{ position: "absolute", left: x, top: yy, opacity: 0.9 }}>
            <Bird size={size} flap={flap} />
          </div>
        );
      })}
    </>
  );
};
