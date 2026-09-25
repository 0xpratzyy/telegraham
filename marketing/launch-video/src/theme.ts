import type { ChannelId } from "./timeline";

// Mirrors the pidgy.chat site tokens.
export const C = {
  page: "#1C1C1E",
  bg1: "#333333",
  bg2: "#3A3A3A",
  bg3: "#424242",
  bg4: "#4D4D4D",
  fg1: "rgba(255,255,255,0.92)",
  fg2: "rgba(255,255,255,0.62)",
  fg3: "rgba(255,255,255,0.42)",
  fg4: "rgba(255,255,255,0.26)",
  border1: "rgba(255,255,255,0.06)",
  border2: "rgba(255,255,255,0.10)",
  border3: "rgba(255,255,255,0.16)",
  accent: "#5B8DEF",
  accentFg: "#A8C2F5",
  accentSoft: "rgba(91,141,239,0.14)",
  accentSoftHi: "rgba(91,141,239,0.22)",
  success: "#5BD18B",
  warning: "#F4B740",
  danger: "#E5484D",
  onMe: "#EA8C32",
  onMeBg: "rgba(234,140,50,0.2)",
  onMeBorder: "rgba(234,140,50,0.4)",
  onThem: "rgba(100,180,255,0.75)",
  onThemBg: "rgba(100,180,255,0.1)",
  onThemBorder: "rgba(100,180,255,0.2)",
  cta: "#1D6FF3",
  sky: "#1E63C4",
  av: ["#C94540", "#C86A31", "#B28D2F", "#438A52", "#3F73BF", "#7B48B4", "#B3457D"],
};

export const FONT = {
  display: "'Newsreader', 'Iowan Old Style', Georgia, serif",
  ui: "'Inter', system-ui, sans-serif",
  mono: "'JetBrains Mono', ui-monospace, monospace",
};

export const CHANNEL: Record<ChannelId, { name: string; live: boolean }> = {
  telegram: { name: "Telegram", live: true },
  slack: { name: "Slack", live: false },
  gmail: { name: "Gmail", live: false },
  whatsapp: { name: "WhatsApp", live: false },
};
