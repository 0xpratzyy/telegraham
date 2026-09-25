import React from "react";
import { useCurrentFrame } from "remotion";
import { clamp, ease } from "../fx/easing";
import { FONT } from "../theme";

/**
 * Calm headline: words drift up out of a soft blur, then leave the same way.
 */
export const Line: React.FC<{
  text: string;
  inAt: number;
  outAt?: number;
  size?: number;
  font?: "display" | "ui";
  weight?: number;
  color?: string;
  stagger?: number;
  style?: React.CSSProperties;
  italic?: boolean;
}> = ({ text, inAt, outAt = 1e9, size = 96, font = "display", weight, color = "white", stagger = 5, style, italic }) => {
  const frame = useCurrentFrame();
  const words = text.split(" ");
  return (
    <div
      style={{
        fontFamily: FONT[font],
        fontSize: size,
        fontWeight: weight ?? (font === "display" ? 500 : 400),
        fontStyle: italic ? "italic" : "normal",
        letterSpacing: font === "display" ? -size * 0.02 : -size * 0.01,
        lineHeight: 1.12,
        color,
        textAlign: "center",
        textShadow: "0 2px 30px rgba(0,0,0,0.25)",
        ...style,
      }}
    >
      {words.map((w, i) => {
        const p = ease.snap(clamp((frame - inAt - i * stagger) / 36));
        const q = ease.inOutCubic(clamp((frame - outAt - i * 2) / 20));
        return (
          <span
            key={i}
            style={{
              display: "inline-block",
              whiteSpace: "pre",
              opacity: p * (1 - q),
              filter: `blur(${(1 - p) * 12 + q * 10}px)`,
              transform: `translateY(${(1 - p) * 22 - q * 14}px)`,
            }}
          >
            {w}
            {i < words.length - 1 ? " " : ""}
          </span>
        );
      })}
    </div>
  );
};
