import React from "react";
import { AbsoluteFill, Img, random, staticFile, useCurrentFrame } from "remotion";

export const Grain: React.FC<{ opacity?: number }> = ({ opacity = 0.07 }) => {
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

export const Vignette: React.FC<{ strength?: number }> = ({ strength = 0.55 }) => (
  <AbsoluteFill
    style={{
      background: `radial-gradient(ellipse at 50% 50%, rgba(0,0,0,0) 55%, rgba(0,0,0,${strength}) 100%)`,
      pointerEvents: "none",
    }}
  />
);

/** Soft moving colour blobs used as a living backdrop. */
export const Aurora: React.FC<{ colors: string[]; opacity?: number; speed?: number; seed?: string }> = ({
  colors,
  opacity = 0.5,
  speed = 1,
  seed = "a",
}) => {
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill style={{ overflow: "hidden", opacity }}>
      {colors.map((c, i) => {
        const t = frame * 0.004 * speed + i * 2.1 + random(seed + i) * 6;
        const x = 50 + Math.cos(t) * 30;
        const y = 50 + Math.sin(t * 1.3) * 26;
        return (
          <div
            key={i}
            style={{
              position: "absolute",
              left: `${x}%`,
              top: `${y}%`,
              width: 1100,
              height: 1100,
              marginLeft: -550,
              marginTop: -550,
              borderRadius: "50%",
              background: `radial-gradient(circle, ${c} 0%, rgba(0,0,0,0) 62%)`,
              filter: "blur(40px)",
            }}
          />
        );
      })}
    </AbsoluteFill>
  );
};

/** Perspective grid floor, gives feature scenes depth. */
export const GridFloor: React.FC<{ color?: string; opacity?: number }> = ({ color = "rgba(145,172,232,0.5)", opacity = 0.18 }) => {
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill style={{ perspective: 900, overflow: "hidden", opacity }}>
      <div
        style={{
          position: "absolute",
          left: "-50%",
          width: "200%",
          top: "52%",
          height: "140%",
          transform: "rotateX(72deg)",
          transformOrigin: "50% 0%",
          backgroundImage: `linear-gradient(${color} 1px, transparent 1px), linear-gradient(90deg, ${color} 1px, transparent 1px)`,
          backgroundSize: "80px 80px",
          backgroundPosition: `0px ${(frame * 1.2) % 80}px`,
          maskImage: "linear-gradient(to bottom, rgba(0,0,0,1), rgba(0,0,0,0) 70%)",
          WebkitMaskImage: "linear-gradient(to bottom, rgba(0,0,0,1), rgba(0,0,0,0) 70%)",
        }}
      />
    </AbsoluteFill>
  );
};

/** Anamorphic light-leak streak. */
export const LightStreak: React.FC<{ y: number; intensity: number; color?: string }> = ({ y, intensity, color = "#91ACE8" }) => (
  <div
    style={{
      position: "absolute",
      left: 0,
      right: 0,
      top: y - 3,
      height: 6,
      background: `linear-gradient(90deg, transparent, ${color}, white, ${color}, transparent)`,
      opacity: intensity,
      filter: "blur(4px)",
      mixBlendMode: "screen",
    }}
  />
);

export const Flash: React.FC<{ amount: number; color?: string }> = ({ amount, color = "white" }) =>
  amount <= 0.001 ? null : <AbsoluteFill style={{ background: color, opacity: amount, pointerEvents: "none" }} />;

export const MascotImg: React.FC<{ size: number; radius?: number; style?: React.CSSProperties }> = ({ size, radius = 0.22, style }) => (
  <Img
    src={staticFile("img/pidgy-mascot.png")}
    style={{ width: size, height: size, borderRadius: size * radius, display: "block", ...style }}
  />
);
