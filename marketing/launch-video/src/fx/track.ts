import { clamp, ease } from "./easing";

/**
 * Piecewise keyframe track: `points` are [frame, value] pairs sorted by
 * frame. Each segment is eased independently, so the camera always settles
 * into a key and leaves it smoothly.
 */
export const track = (frame: number, points: [number, number][], fn: (t: number) => number = ease.inOutCubic) => {
  if (frame <= points[0][0]) return points[0][1];
  for (let i = 1; i < points.length; i++) {
    const [f1, v1] = points[i];
    const [f0, v0] = points[i - 1];
    if (frame <= f1) return v0 + (v1 - v0) * fn(clamp((frame - f0) / (f1 - f0)));
  }
  return points[points.length - 1][1];
};

/** 0..1 visibility envelope: fade in at `inAt`, fade out at `outAt`. */
export const env = (frame: number, inAt: number, outAt: number, inDur = 24, outDur = 18) =>
  ease.snap(clamp((frame - inAt) / inDur)) * (1 - ease.inOutCubic(clamp((frame - outAt) / outDur)));
