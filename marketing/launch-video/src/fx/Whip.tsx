import React from "react";
import { useCurrentFrame } from "remotion";
import { Camera } from "./Camera";
import { clamp, ease } from "./easing";

/**
 * Whip-pan in from the right at the start of a scene and out to the left at
 * the end, with horizontal motion blur proportional to velocity.
 */
export const Whip: React.FC<{ children: React.ReactNode; dur: number; inFrames?: number; outFrames?: number; id: string; dir?: 1 | -1 }> = ({
  children,
  dur,
  inFrames = 13,
  outFrames = 10,
  id,
  dir = 1,
}) => {
  const frame = useCurrentFrame();
  const pin = clamp(frame / inFrames);
  const pout = clamp((frame - (dur - outFrames)) / outFrames);
  const xin = (1 - ease.outExpo(pin)) * 1100;
  const xout = -ease.inExpo(pout) * 1300;
  const vin = frame < inFrames ? Math.abs(1100 * (ease.outExpo(clamp((frame + 1) / inFrames)) - ease.outExpo(pin))) : 0;
  const vout = pout > 0 ? Math.abs(1300 * (ease.inExpo(clamp((frame + 1 - (dur - outFrames)) / outFrames)) - ease.inExpo(pout))) : 0;
  const blur = Math.min(90, (vin + vout) * 0.35);
  return (
    <Camera id={id} x={dir * (xin + xout)} blurX={blur} zoom={1 + (1 - ease.outExpo(pin)) * 0.08 + ease.inExpo(pout) * 0.06}>
      {children}
    </Camera>
  );
};
