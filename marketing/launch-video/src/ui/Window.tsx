import React from "react";
import { C, FONT } from "../theme";

/** macOS window chrome in Pidgy surface tokens. */
export const Window: React.FC<{
  width: number;
  height?: number;
  title?: string;
  children: React.ReactNode;
  style?: React.CSSProperties;
  glow?: number;
}> = ({ width, height, title, children, style, glow = 0.5 }) => (
  <div
    style={{
      width,
      height,
      background: C.bg0,
      borderRadius: 18,
      border: `1px solid ${C.border3}`,
      boxShadow: `0 60px 140px rgba(0,0,0,0.6), 0 0 0 1px rgba(0,0,0,0.4), 0 0 120px rgba(79,127,220,${0.28 * glow})`,
      overflow: "hidden",
      fontFamily: FONT.ui,
      color: C.fg1,
      position: "relative",
      ...style,
    }}
  >
    <div
      style={{
        height: 44,
        display: "flex",
        alignItems: "center",
        padding: "0 18px",
        gap: 8,
        background: C.bg1,
        borderBottom: `1px solid ${C.border1}`,
      }}
    >
      {["#FF5F57", "#FEBC2E", "#28C840"].map((c) => (
        <div key={c} style={{ width: 13, height: 13, borderRadius: 7, background: c }} />
      ))}
      <div style={{ flex: 1, textAlign: "center", fontSize: 14, color: C.fg3, fontWeight: 500, marginRight: 60 }}>{title}</div>
    </div>
    {children}
  </div>
);

export const Avatar: React.FC<{ name: string; size: number; color: string; style?: React.CSSProperties }> = ({ name, size, color, style }) => (
  <div
    style={{
      width: size,
      height: size,
      borderRadius: "50%",
      background: `linear-gradient(145deg, ${color}, ${shade(color, -0.25)})`,
      color: "white",
      fontFamily: FONT.ui,
      fontWeight: 600,
      fontSize: size * 0.4,
      display: "flex",
      alignItems: "center",
      justifyContent: "center",
      flex: "none",
      ...style,
    }}
  >
    {name
      .split(" ")
      .map((w) => w[0])
      .slice(0, 2)
      .join("")}
  </div>
);

const shade = (hex: string, amt: number) => {
  const n = parseInt(hex.slice(1), 16);
  const f = (v: number) => Math.max(0, Math.min(255, Math.round(v + v * amt)));
  return `rgb(${f(n >> 16)}, ${f((n >> 8) & 255)}, ${f(n & 255)})`;
};

export const Chip: React.FC<{ children: React.ReactNode; color?: string; bg?: string; style?: React.CSSProperties }> = ({
  children,
  color = C.accentFg,
  bg = C.accentSoft,
  style,
}) => (
  <span
    style={{
      display: "inline-flex",
      alignItems: "center",
      gap: 6,
      padding: "4px 10px",
      borderRadius: 999,
      background: bg,
      color,
      fontSize: 13,
      fontWeight: 600,
      fontFamily: FONT.ui,
      letterSpacing: 0.2,
      ...style,
    }}
  >
    {children}
  </span>
);
