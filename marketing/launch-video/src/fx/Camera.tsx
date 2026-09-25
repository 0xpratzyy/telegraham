import React from "react";
import { AbsoluteFill, useCurrentFrame } from "remotion";
import { wobble } from "./easing";

/**
 * Wraps a scene in a virtual camera. `shake` is 0..1 intensity, `zoom` scale,
 * `x/y` pan in px, `rot` roll in degrees, `blurX` directional motion blur.
 */
export const Camera: React.FC<{
  children: React.ReactNode;
  shake?: number;
  zoom?: number;
  x?: number;
  y?: number;
  rot?: number;
  blurX?: number;
  blurY?: number;
  id?: string;
}> = ({ children, shake = 0, zoom = 1, x = 0, y = 0, rot = 0, blurX = 0, blurY = 0, id = "cam" }) => {
  const frame = useCurrentFrame();
  const sx = wobble(frame, `${id}x`, 0.9) * 26 * shake;
  const sy = wobble(frame, `${id}y`, 0.9) * 18 * shake;
  const sr = wobble(frame, `${id}r`, 0.6) * 1.2 * shake;
  const filterId = `mb-${id}`;
  const blurred = blurX > 0.3 || blurY > 0.3;
  return (
    <AbsoluteFill>
      {blurred && (
        <svg width="0" height="0" style={{ position: "absolute" }}>
          <filter id={filterId} x="-20%" y="-20%" width="140%" height="140%">
            <feGaussianBlur stdDeviation={`${blurX} ${blurY}`} />
          </filter>
        </svg>
      )}
      <AbsoluteFill
        style={{
          transform: `translate(${x + sx}px, ${y + sy}px) rotate(${rot + sr}deg) scale(${zoom})`,
          filter: blurred ? `url(#${filterId})` : undefined,
        }}
      >
        {children}
      </AbsoluteFill>
    </AbsoluteFill>
  );
};
