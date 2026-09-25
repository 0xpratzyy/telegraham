import React from "react";
import { C, FONT } from "../theme";

export const Avatar: React.FC<{ name: string; size: number; color: string; style?: React.CSSProperties }> = ({ name, size, color, style }) => (
  <div
    style={{
      width: size,
      height: size,
      borderRadius: "50%",
      background: color,
      color: "rgba(255,255,255,0.95)",
      fontFamily: FONT.ui,
      fontWeight: 600,
      fontSize: size * 0.42,
      display: "flex",
      alignItems: "center",
      justifyContent: "center",
      flex: "none",
      ...style,
    }}
  >
    {name.replace(/[^A-Za-z]/g, "")[0]?.toUpperCase()}
  </div>
);

export type Who = "me" | "them" | "quiet";

export const Badge: React.FC<{ who: Who; size?: number; style?: React.CSSProperties }> = ({ who, size = 15, style }) => {
  const [fg, bg, bd, label] =
    who === "me"
      ? [C.onMe, C.onMeBg, C.onMeBorder, "ON ME"]
      : who === "them"
        ? [C.onThem, C.onThemBg, C.onThemBorder, "ON THEM"]
        : [C.fg3, "rgba(255,255,255,0.06)", C.border2, "QUIET"];
  return (
    <span
      style={{
        fontFamily: FONT.ui,
        fontSize: size,
        fontWeight: 700,
        letterSpacing: size * 0.06,
        color: fg,
        background: bg,
        border: `1px solid ${bd}`,
        padding: `${size * 0.2}px ${size * 0.55}px`,
        borderRadius: size * 0.4,
        lineHeight: 1.2,
        ...style,
      }}
    >
      {label}
    </span>
  );
};
