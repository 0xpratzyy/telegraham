import React from "react";
import { clamp, ease } from "../fx/easing";
import { IGrid, ISearch } from "./Icons";
import { A, F } from "./tokens";

// Recreation of LauncherView (the ⌘⇧T panel): 640 x 480 pt, search bar,
// All / DMs / Groups filter tags, pattern-match rows with WALLET / YOU
// capsules, and the "✦ PIDGY" answer card. Demo data only.
export const PANEL_W = 640;
export const PANEL_H = 480;

const successSoft = "rgba(78,190,122,0.14)";

const Avatar: React.FC<{ name: string; color: string }> = ({ name, color }) => (
  <div style={{ width: 28, height: 28, borderRadius: 14, background: color, color: "white", fontFamily: F.ui, fontSize: 11, fontWeight: 600, display: "flex", alignItems: "center", justifyContent: "center", flex: "none" }}>
    {name
      .split(" ")
      .map((w) => w[0])
      .slice(0, 2)
      .join("")}
  </div>
);

type Match = { chat: string; when: string; before: string; hit: string; after: string; color: string };
const WALLET_HITS: Match[] = [
  { chat: "Aman Verma", when: "3w", before: "Here's the wallet for the pilot: ", hit: "0x7a3F…c91E", after: "", color: A.av[4] },
  { chat: "Nova Labs <> Pidgy", when: "5w", before: "treasury wallet → ", hit: "0x7a3F…c91E", after: " (same one as Aman)", color: A.av[5] },
];

const PatternRow: React.FC<{ m: Match; selected: boolean; appear: number }> = ({ m, selected, appear }) => (
  <div
    style={{
      display: "flex",
      gap: 8,
      padding: "6px 8px",
      borderRadius: 8,
      background: selected ? A.bg4 : "transparent",
      opacity: appear,
      transform: `translateY(${(1 - appear) * 8}px)`,
      fontFamily: F.ui,
    }}
  >
    <Avatar name={m.chat} color={m.color} />
    <div style={{ flex: 1, minWidth: 0 }}>
      <div style={{ display: "flex", alignItems: "center", gap: 5 }}>
        <span style={{ fontSize: 14, fontWeight: 500, color: A.fg1 }}>{m.chat}</span>
        <span style={{ fontSize: 9.5, fontWeight: 700, letterSpacing: 0.6, color: A.success, background: successSoft, padding: "1px 5px", borderRadius: 99 }}>WALLET</span>
        <span style={{ fontSize: 9.5, fontWeight: 700, letterSpacing: 0.6, color: A.success, background: successSoft, padding: "1px 5px", borderRadius: 99 }}>YOU</span>
        <span style={{ marginLeft: "auto", fontFamily: F.mono, fontSize: 11, color: A.fg2 }}>{m.when}</span>
      </div>
      <div style={{ fontSize: 13, color: A.fg2, marginTop: 2 }}>
        {m.before}
        <span style={{ fontFamily: F.mono, fontSize: 12, color: A.fg1, background: selected ? "rgba(78,190,122,0.18)" : "transparent", padding: "0 3px", borderRadius: 3 }}>{m.hit}</span>
        {m.after}
      </div>
    </div>
  </div>
);

export const LauncherPanel: React.FC<{
  query: string;
  typed: number;
  caret: boolean;
  mode: "idle" | "wallet" | "answer";
  resultT: number;
  thinking: number;
}> = ({ query, typed, caret, mode, resultT, thinking }) => {
  const shown = query.slice(0, typed);
  return (
    <div
      style={{
        width: PANEL_W,
        height: PANEL_H,
        borderRadius: 14,
        background: "rgba(36,36,36,0.97)",
        border: `1px solid ${A.border3}`,
        boxShadow: "0 30px 90px rgba(0,0,0,0.5), 0 0 0 0.5px rgba(0,0,0,0.6)",
        overflow: "hidden",
        fontFamily: F.ui,
        color: A.fg1,
      }}
    >
      <div style={{ display: "flex", alignItems: "center", gap: 10, padding: "12px 12px 10px" }}>
        <span style={{ color: A.fg3, display: "flex" }}>
          <ISearch size={15} />
        </span>
        <div style={{ flex: 1, fontSize: 14, whiteSpace: "pre", opacity: mode === "answer" && thinking > 0 && thinking < 1 ? 0.55 + 0.45 * Math.abs(Math.cos(thinking * Math.PI * 2)) : 1 }}>
          {typed === 0 ? <span style={{ color: A.fg3 }}>Search Telegram...</span> : shown}
          <span style={{ display: "inline-block", width: 1.5, height: 16, marginLeft: 1, verticalAlign: "-3px", background: A.fg1, opacity: caret ? 1 : 0 }} />
        </div>
        <span style={{ display: "flex", alignItems: "center", gap: 4 }}>
          <span style={{ width: 6, height: 6, borderRadius: 3, background: A.success }} />
          <span style={{ fontFamily: F.mono, fontSize: 11, color: A.fg3 }}>Pratyush</span>
        </span>
        <span style={{ color: A.fg3, display: "flex" }}>
          <IGrid size={13} />
        </span>
      </div>
      <div style={{ display: "flex", gap: 2, padding: "0 8px 6px" }}>
        {["All", "DMs", "Groups"].map((f, i) => (
          <span key={f} style={{ padding: "3px 8px", fontSize: i === 0 ? 10.5 : 11, fontWeight: i === 0 ? 600 : 400, letterSpacing: i === 0 ? 0.4 : 0, color: i === 0 ? A.fg1 : A.fg3 }}>
            {f}
          </span>
        ))}
      </div>
      <div style={{ height: 1, background: A.border1 }} />
      <div style={{ padding: "8px 8px" }}>
        {mode === "idle" && (
          <div style={{ padding: "4px 8px", fontFamily: F.mono, fontSize: 11, color: A.fg3 }}>RECENT</div>
        )}
        {mode === "idle" &&
          ["Aman Verma", "Akhil", "Nova Labs <> Pidgy", "Founders only", "Priya Shah", "Kenji Mori"].map((n, i) => (
            <div key={n} style={{ display: "flex", alignItems: "center", gap: 8, padding: "6px 8px", borderRadius: 8, background: i === 0 ? A.bg4 : "transparent" }}>
              <Avatar name={n} color={A.av[(i * 3) % 7]} />
              <div style={{ flex: 1 }}>
                <div style={{ fontSize: 14, fontWeight: 500 }}>{n}</div>
                <div style={{ fontSize: 12.5, color: A.fg3 }}>{["bumping this", "sounds good, lmk", "deck v3 attached", "who's in for friday?", "can we move to 4?", "sent"][i]}</div>
              </div>
              <span style={{ fontFamily: F.mono, fontSize: 11, color: A.fg2 }}>{["29m", "41m", "2h", "3h", "5h", "9h"][i]}</span>
            </div>
          ))}
        {mode === "wallet" && (
          <>
            <div style={{ padding: "4px 8px 6px", fontFamily: F.mono, fontSize: 11, color: A.fg3, opacity: clamp(resultT / 8) }}>2 results</div>
            {WALLET_HITS.map((m, i) => (
              <PatternRow key={m.chat} m={m} selected={i === 0} appear={ease.snap(clamp((resultT - i * 5) / 16))} />
            ))}
            <div style={{ height: 1, background: A.border1, margin: "10px 0 4px", opacity: clamp((resultT - 12) / 10) }} />
            <div style={{ display: "flex", alignItems: "center", gap: 8, padding: "6px 10px", fontSize: 13, opacity: clamp((resultT - 14) / 10) }}>
              <span style={{ color: A.accent }}>✦</span>
              <span style={{ color: A.fg2 }}>Ask Pidgy about “{query}”</span>
              <span style={{ marginLeft: "auto", fontFamily: F.mono, fontSize: 11, color: A.fg3 }}>⏎</span>
            </div>
          </>
        )}
        {mode === "answer" && (
          <div style={{ padding: "6px 10px" }}>
            {thinking < 1 ? (
              <div style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 13, color: A.fg3 }}>
                <span style={{ width: 12, height: 12, borderRadius: 6, border: `2px solid ${A.fg4}`, borderTopColor: A.fg2, transform: `rotate(${thinking * 720}deg)` }} />
                Pidgy is thinking…
              </div>
            ) : (
              <div style={{ opacity: ease.snap(clamp(resultT / 14)) }}>
                <div style={{ fontFamily: F.mono, fontSize: 11, color: A.accent }}>✦ PIDGY</div>
                <div style={{ fontSize: 13.5, lineHeight: 1.55, color: A.fg1, marginTop: 5 }}>
                  You agreed to a <b>2-week pilot at $4k</b>. <b>Akhil</b> asked for an SLA. You said you'd send it <b>Friday</b>.
                </div>
                <div style={{ marginTop: 14, fontFamily: F.mono, fontSize: 11, color: A.fg3, opacity: clamp((resultT - 12) / 10) }}>FACTS</div>
                {[
                  ["DEAL", "2-week pilot · $4k", "Akhil · Akhil <> Pidgy"],
                  ["ASK", "SLA doc", "Akhil · Akhil <> Pidgy"],
                  ["DUE", "Friday", "You · Akhil <> Pidgy"],
                ].map(([k, v, src], i) => (
                  <div key={k} style={{ display: "flex", alignItems: "baseline", gap: 8, marginTop: 7, opacity: ease.snap(clamp((resultT - 14 - i * 5) / 14)) }}>
                    <span style={{ fontFamily: F.mono, fontSize: 11, color: A.fg3, width: 56 }}>{k}</span>
                    <span style={{ fontSize: 13, color: A.fg1 }}>{v}</span>
                    <span style={{ marginLeft: "auto", fontFamily: F.mono, fontSize: 11, color: A.fg3 }}>{src}</span>
                  </div>
                ))}
              </div>
            )}
          </div>
        )}
      </div>
    </div>
  );
};

