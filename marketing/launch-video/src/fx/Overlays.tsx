import React from "react";
import { AbsoluteFill, Img, random, staticFile, useCurrentFrame } from "remotion";

export const Grain: React.FC<{ opacity?: number }> = ({ opacity = 0.05 }) => {
  const frame = useCurrentFrame();
  const x = Math.floor(random(`gx${frame}`) * 512);
  const y = Math.floor(random(`gy${frame}`) * 512);
  return (
    <AbsoluteFill
      style={{
        backgroundImage: `url(${staticFile("img/noise.png")})`,
        backgroundPosition: `${x}px ${y}px`,
        backgroundSize: "512px 512px",
        mixBlendMode: "overlay",
        opacity,
        pointerEvents: "none",
      }}
    />
  );
};

export const Vignette: React.FC<{ strength?: number }> = ({ strength = 0.3 }) => (
  <AbsoluteFill
    style={{
      background: `radial-gradient(ellipse at 50% 50%, rgba(0,0,0,0) 60%, rgba(0,0,0,${strength}) 100%)`,
      pointerEvents: "none",
    }}
  />
);

/** The white-framed squircle app icon used in the pidgy.chat hero. */
export const AppIcon: React.FC<{ size: number; style?: React.CSSProperties }> = ({ size, style }) => (
  <div
    style={{
      width: size,
      height: size,
      padding: size * 0.03,
      background: "#fff",
      borderRadius: size * 0.286,
      boxShadow: `0 ${size * 0.06}px ${size * 0.14}px rgba(0,0,0,0.18)`,
      boxSizing: "border-box",
      ...style,
    }}
  >
    <Img
      src={staticFile("img/pidgy-mascot.png")}
      style={{ width: "100%", height: "100%", borderRadius: size * 0.26, display: "block", objectFit: "cover" }}
    />
  </div>
);
