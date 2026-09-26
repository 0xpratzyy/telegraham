import React from "react";
import type { ChannelId } from "../timeline";

// Telegram / Slack / Gmail marks are the same artwork shipped in
// Sources/Resources/Assets.xcassets. WhatsApp has no asset in the app bundle
// yet, so it is drawn here from primitives.
export const Glyph: React.FC<{ id: ChannelId; size: number; tile?: boolean; style?: React.CSSProperties }> = ({
  id,
  size,
  tile = false,
  style,
}) => {
  const inner = (() => {
    switch (id) {
      case "telegram":
        return (
          <svg viewBox="0 0 240 240" width={size} height={size}>
            <defs>
              <linearGradient id="tg-grad" x1="0.5" y1="0" x2="0.5" y2="1">
                <stop offset="0" stopColor="#37BBFE" />
                <stop offset="1" stopColor="#007DBB" />
              </linearGradient>
            </defs>
            <circle cx="120" cy="120" r="120" fill="url(#tg-grad)" />
            <path
              fill="#fff"
              d="M81 128.6 54.4 120c-5.8-1.8-5.8-5.7 1.3-8.6l130-50.2c4.7-2.1 9.2 1.1 7.4 8.6l-22.1 104.3c-1.5 7.4-6 9.2-12.2 5.7L125 154.4l-15.9 15.4c-1.6 1.6-3 3-5.7 3l2-28.6 52-47c2.3-2-.5-3.1-3.5-1.1L90.4 136.6Z"
            />
          </svg>
        );
      case "slack":
        return (
          <svg viewBox="0 0 24 24" width={size * (tile ? 0.62 : 1)} height={size * (tile ? 0.62 : 1)}>
            <path fill="#E01E5A" d="M5.04 15.16a2.5 2.5 0 1 1-2.5-2.5h2.5v2.5Zm1.26 0a2.5 2.5 0 0 1 5 0v6.26a2.5 2.5 0 1 1-5 0v-6.26Z" />
            <path fill="#36C5F0" d="M8.8 5.04a2.5 2.5 0 1 1 2.5-2.5v2.5H8.8Zm0 1.26a2.5 2.5 0 0 1 0 5H2.54a2.5 2.5 0 1 1 0-5H8.8Z" />
            <path fill="#2EB67D" d="M18.96 8.8a2.5 2.5 0 1 1 2.5 2.5h-2.5V8.8Zm-1.26 0a2.5 2.5 0 0 1-5 0V2.54a2.5 2.5 0 1 1 5 0V8.8Z" />
            <path fill="#ECB22E" d="M15.2 18.96a2.5 2.5 0 1 1-2.5 2.5v-2.5h2.5Zm0-1.26a2.5 2.5 0 0 1 0-5h6.26a2.5 2.5 0 1 1 0 5H15.2Z" />
          </svg>
        );
      case "gmail":
        return (
          <svg viewBox="0 0 256 193" width={size * (tile ? 0.62 : 1)} height={size * (tile ? 0.62 : 1) * (193 / 256)}>
            <path fill="#4285F4" d="M58.182 192.05V93.14L27.507 65.077 0 49.504v125.091c0 9.658 7.825 17.455 17.455 17.455z" />
            <path fill="#34A853" d="M197.818 192.05h40.727c9.659 0 17.455-7.826 17.455-17.455V49.505l-31.156 17.837-27.026 25.798z" />
            <path fill="#FBBC04" d="M197.818 17.504V93.14L256 49.504V26.231c0-21.585-24.64-33.89-41.89-20.945z" />
            <path fill="#EA4335" d="M58.182 93.14l-4.174-38.647 4.174-36.989L128 69.868l69.818-52.364 4.667 33.95-4.667 41.686L128 145.504z" />
            <path fill="#C5221F" d="M0 49.504l26.759 20.07L58.182 93.14V17.504L41.89 5.286C24.61-7.66 0 4.646 0 26.23z" />
          </svg>
        );
      case "whatsapp":
        return (
          <svg viewBox="0 0 240 240" width={size} height={size}>
            <circle cx="120" cy="120" r="120" fill="#25D366" />
            <path
              fill="none"
              stroke="#fff"
              strokeWidth="15"
              strokeLinejoin="round"
              d="M120 52a68 68 0 0 0-58.6 102.6L52 188l34.6-9.1A68 68 0 1 0 120 52Z"
            />
            <path
              fill="#fff"
              d="M94.5 88.6c2-.1 4.2 0 5.3 2.6 1.4 3.2 4.4 11 4.8 11.8.4.8.6 1.7.1 2.8-2 4.2-4.2 4.6-2.6 7.4 6 10.3 12 13.9 21 18.5 1.6.8 2.5.7 3.4-.4 1-1.2 4.1-4.8 5.2-6.4 1.1-1.6 2.2-1.4 3.7-.8 1.5.5 9.6 4.5 11.2 5.3 1.6.8 2.7 1.2 3.1 1.9.4.7.4 4-1 7.8-1.4 3.9-8 7.4-11.1 7.7-2.9.3-5.6 1.4-18.6-3.9-15.7-6.4-25.7-22.6-26.4-23.6-.8-1-6.3-8.4-6.3-16.1 0-7.7 4-11.4 5.5-13 1.3-1.4 2.6-1.6 3.7-1.6Z"
            />
          </svg>
        );
    }
  })();

  if (!tile) return <span style={{ display: "inline-flex", ...style }}>{inner}</span>;
  const bg = id === "slack" || id === "gmail" ? "#fff" : "transparent";
  return (
    <span
      style={{
        width: size,
        height: size,
        borderRadius: id === "slack" || id === "gmail" ? size * 0.26 : "50%",
        background: bg,
        display: "inline-flex",
        alignItems: "center",
        justifyContent: "center",
        flex: "none",
        ...style,
      }}
    >
      {inner}
    </span>
  );
};
