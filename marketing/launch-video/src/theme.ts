import type { ChannelId } from "./timeline";

// Mirrors Sources/DesignSystem/PidgyTokens.swift.
export const C = {
  bg0: "#242424",
  bg1: "#2B2B2B",
  bg2: "#323232",
  bg3: "#393939",
  bg4: "#444444",
  void: "#0A0B0E",
  ink: "#111317",
  fg1: "rgba(255,255,255,0.92)",
  fg2: "rgba(255,255,255,0.62)",
  fg3: "rgba(255,255,255,0.42)",
  fg4: "rgba(255,255,255,0.26)",
  border1: "rgba(255,255,255,0.06)",
  border2: "rgba(255,255,255,0.10)",
  border3: "rgba(255,255,255,0.16)",
  accent: "#4F7FDC",
  accentHover: "#6E96E8",
  accentPress: "#3869CA",
  accentSoft: "rgba(79,127,220,0.14)",
  accentSoftHi: "rgba(79,127,220,0.22)",
  accentRing: "rgba(79,127,220,0.45)",
  accentFg: "#91ACE8",
  success: "#4EBE7A",
  warning: "#D99B2D",
  danger: "#D63D43",
  // Mascot photo backdrop + iridescent neck feathers.
  mascotBlue: "#0B5CF0",
  teal: "#3FE0C5",
  violet: "#6A3DE8",
  av: ["#C94540", "#C86A31", "#B28D2F", "#438A52", "#3F73BF", "#7B48B4", "#B3457D"],
};

export const FONT = {
  display: "'Newsreader', Georgia, serif",
  ui: "'Inter', system-ui, sans-serif",
  mono: "'JetBrains Mono', ui-monospace, monospace",
};

export const CHANNEL: Record<ChannelId, { name: string; color: string; tint: string; desc: string }> = {
  telegram: { name: "Telegram", color: "#2AABEE", tint: "#37BBFE", desc: "DMs · Groups · Channels" },
  slack: { name: "Slack", color: "#4A154B", tint: "#E01E5A", desc: "Workspaces · Threads" },
  gmail: { name: "Gmail", color: "#EA4335", tint: "#EA4335", desc: "Threads · Senders · Labels" },
  whatsapp: { name: "WhatsApp", color: "#25D366", tint: "#25D366", desc: "Chats · Groups" },
};
