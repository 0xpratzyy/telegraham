import React from "react";
import { Img, staticFile } from "remotion";
import { clamp, ease } from "../fx/easing";
import { ICheck, IChevronDown, IBubble, IClose, IHome, IPeople, IRefresh, ISearch, ISidebar, ISparkle, ITray, IArrowDown, IArrowUp, IPlane } from "./Icons";
import { PigeonFlock } from "./Pigeons";
import { A, F } from "./tokens";

// Recreation of the Pidgy dashboard window (DashboardView + sidebar +
// Home / Reply queue pages + inspector), laid out in macOS points from the
// Aug 15 audit screenshots. Demo data only.
export const WIN_W = 1512;
export const WIN_H = 930;
const SIDEBAR = 240;
const INSPECTOR = 420;

type Row = { name: string; sub: string; time: string; ctx?: string; color: string };

export const QUEUE: Row[] = [
  { name: "Aman Verma", sub: "Send Aman the wallet for the pilot", time: "29m", color: A.av[4] },
  { name: "Akhil", sub: "Reply to Akhil on the SLA", time: "41m", color: A.av[1] },
  { name: "Kenji Mori", sub: "Share the term sheet draft Kenji asked for", time: "2h", ctx: "Nova Labs <> Pidgy", color: A.av[5] },
  { name: "Priya Shah", sub: "Confirm Friday's demo time", time: "3h", color: A.av[6] },
  { name: "Sara Lin", sub: "Answer Sara's question about pricing", time: "5h", ctx: "Founders only", color: A.av[3] },
  { name: "Dmitri", sub: "Follow up on the intro to the Base team", time: "9h", color: A.av[0] },
  { name: "Lena Park", sub: "Send the latency numbers she asked for", time: "1d", color: A.av[2] },
  { name: "Theo Dale", sub: "Reply to Theo about the contract", time: "2d", ctx: "BD pipeline", color: A.av[7] },
  { name: "Maya", sub: "Review the onboarding copy", time: "3d", color: A.av[4] },
];

const Avatar: React.FC<{ name: string; size: number; color: string }> = ({ name, size, color }) => (
  <div
    style={{
      width: size,
      height: size,
      borderRadius: "50%",
      background: color,
      color: "rgba(255,255,255,0.95)",
      fontFamily: F.ui,
      fontWeight: 600,
      fontSize: size * 0.38,
      display: "flex",
      alignItems: "center",
      justifyContent: "center",
      flex: "none",
    }}
  >
    {name
      .split(" ")
      .map((w) => w[0])
      .slice(0, 2)
      .join("")
      .toUpperCase()}
  </div>
);

const Eyebrow: React.FC<{ children: React.ReactNode; color?: string; style?: React.CSSProperties }> = ({ children, color = A.fg3, style }) => (
  <div style={{ fontFamily: F.ui, fontSize: 10.5, fontWeight: 600, letterSpacing: 1.1, color, ...style }}>{children}</div>
);

const Sidebar: React.FC<{ page: "home" | "queue" }> = ({ page }) => {
  const items = [
    { id: "home", label: "Home", icon: IHome, count: "" },
    { id: "queue", label: "Reply queue", icon: ITray, count: "12" },
    { id: "tasks", label: "Tasks", icon: ICheck, count: "7" },
    { id: "people", label: "People", icon: IPeople, count: "1,571" },
  ];
  return (
    <div style={{ position: "absolute", left: 0, top: 0, bottom: 0, width: SIDEBAR, background: A.bg1, borderRight: `1px solid ${A.border1}` }}>
      <div style={{ position: "absolute", left: 16, top: 14, display: "flex", gap: 8 }}>
        {["#FF5F57", "#FEBC2E", "#28C840"].map((c) => (
          <div key={c} style={{ width: 12, height: 12, borderRadius: 6, background: c }} />
        ))}
      </div>
      <div style={{ position: "absolute", left: 94, top: 10, color: A.fg3 }}>
        <ISidebar size={20} />
      </div>
      <div style={{ position: "absolute", left: 13, top: 45, display: "flex", gap: 10, alignItems: "center" }}>
        <Img src={staticFile("img/pidgy-mascot.png")} style={{ width: 37, height: 37, borderRadius: 9 }} />
        <div>
          <div style={{ fontFamily: F.display, fontSize: 19, fontWeight: 500, color: A.fg1, lineHeight: 1 }}>Pidgy</div>
          <div style={{ display: "flex", alignItems: "center", gap: 4, fontFamily: F.ui, fontSize: 13, color: A.fg2, marginTop: 4 }}>
            <IChevronDown size={12} /> Telegram
          </div>
        </div>
      </div>
      <div
        style={{
          position: "absolute",
          left: 8,
          right: 8,
          top: 94,
          height: 29,
          borderRadius: 7,
          background: "rgba(255,255,255,0.05)",
          border: `1px solid ${A.border2}`,
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
          padding: "0 8px 0 10px",
          fontFamily: F.ui,
          fontSize: 13.5,
          color: A.fg3,
        }}
      >
        Ask anything...
        <span style={{ fontFamily: F.mono, fontSize: 10, padding: "1px 5px", borderRadius: 4, border: `1px solid ${A.border2}` }}>⌘K</span>
      </div>
      {items.map((it, i) => {
        const Icon = it.icon;
        const on = it.id === page;
        return (
          <div
            key={it.id}
            style={{
              position: "absolute",
              left: 7,
              right: 7,
              top: 134 + i * 36,
              height: 32,
              borderRadius: 8,
              background: on ? A.bg3 : "transparent",
              display: "flex",
              alignItems: "center",
              gap: 11,
              padding: "0 10px",
              fontFamily: F.ui,
              fontSize: 14,
              color: A.fg1,
            }}
          >
            <span style={{ color: A.fg2, display: "flex" }}>
              <Icon size={17} />
            </span>
            {it.label}
            <span style={{ marginLeft: "auto", fontFamily: F.mono, fontSize: 11.5, color: A.fg2 }}>{it.count}</span>
          </div>
        );
      })}
      <Eyebrow style={{ position: "absolute", left: 17, bottom: 92 }}>MAIN TOPICS</Eyebrow>
      <div style={{ position: "absolute", left: 17, right: 17, bottom: 64, display: "flex", fontFamily: F.ui, fontSize: 13, color: A.fg2 }}>
        <span style={{ color: A.accent, marginRight: 8 }}>•</span> first dollar
        <span style={{ marginLeft: "auto", fontFamily: F.mono, fontSize: 11 }}>12</span>
      </div>
      <div style={{ position: "absolute", left: 14, bottom: 16, display: "flex", alignItems: "center", gap: 9, fontFamily: F.ui, fontSize: 13, color: A.fg2 }}>
        <Avatar name="Pratyush" size={24} color={A.av[1]} /> pratyush
      </div>
    </div>
  );
};

const Header: React.FC<{ title: string; sub: string }> = ({ title, sub }) => (
  <div style={{ position: "absolute", left: SIDEBAR, right: 0, top: 0, height: 80, borderBottom: `1px solid ${A.border1}`, fontFamily: F.ui }}>
    <div style={{ position: "absolute", left: 32, top: 46, fontSize: 14, color: A.fg1, fontWeight: 600 }}>
      {title} <span style={{ color: A.fg3, fontWeight: 400 }}>· {sub}</span>
    </div>
    <div style={{ position: "absolute", right: 22, top: 40, display: "flex", alignItems: "center", gap: 12 }}>
      <span style={{ fontSize: 13, color: A.fg3 }}>Updated just now</span>
      <span style={{ display: "flex", alignItems: "center", gap: 7, padding: "5px 12px", borderRadius: 8, background: A.bg3, border: `1px solid ${A.border2}`, fontSize: 13.5, fontWeight: 600, color: A.fg1 }}>
        <IRefresh size={14} /> Refresh
      </span>
    </div>
  </div>
);

const RowView: React.FC<{ r: Row; appear: number; selected?: number; dense?: boolean }> = ({ r, appear, selected = 0 }) => (
  <div
    style={{
      display: "flex",
      alignItems: "center",
      gap: 12,
      height: 54,
      padding: "0 14px",
      borderRadius: 10,
      background: selected > 0 ? `rgba(57,57,57,${selected})` : "transparent",
      opacity: appear,
      transform: `translateY(${(1 - appear) * 10}px)`,
      fontFamily: F.ui,
    }}
  >
    <Avatar name={r.name} size={30} color={r.color} />
    <div style={{ flex: 1, minWidth: 0 }}>
      <div style={{ fontSize: 14.5, fontWeight: 600, color: A.fg1, whiteSpace: "nowrap" }}>
        {r.name}
        {r.ctx && <span style={{ fontWeight: 400, color: A.fg3 }}> · {r.ctx}</span>}
      </div>
      <div style={{ fontSize: 14, color: A.fg2, marginTop: 3, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{r.sub}</div>
    </div>
    <span style={{ fontFamily: F.mono, fontSize: 12, color: A.accent }}>{r.time}</span>
  </div>
);

const Home: React.FC<{ t: number }> = ({ t }) => (
  <div style={{ position: "absolute", left: SIDEBAR, right: 0, top: 81, bottom: 0 }}>
    <div style={{ position: "absolute", left: 206, width: 860, top: 44 }}>
      <div style={{ fontFamily: F.display, fontSize: 40, fontWeight: 500, letterSpacing: -0.8, color: A.fg1, lineHeight: 1.1 }}>Good afternoon, Pratyush</div>
      <div style={{ fontFamily: F.ui, fontSize: 14, color: A.fg2, marginTop: 10 }}>I found 12 things that need you now. The rest can wait.</div>
      <div style={{ marginTop: 12 }}>
        <PigeonFlock width={860} t={t} arrive={clamp(t / 40)} />
      </div>
      <div
        style={{
          marginTop: 34,
          height: 80,
          borderRadius: 12,
          background: A.bg3,
          border: `1px solid ${A.border2}`,
          display: "flex",
          alignItems: "center",
          gap: 14,
          padding: "0 18px 0 16px",
        }}
      >
        <Img src={staticFile("img/pidgy-mascot.png")} style={{ width: 37, height: 37, borderRadius: 9 }} />
        <div style={{ flex: 1 }}>
          <Eyebrow color={A.accent}>ASK PIDGY</Eyebrow>
          <div style={{ fontFamily: F.ui, fontSize: 15, color: A.fg2, marginTop: 4 }}>Ask about your Telegram...</div>
        </div>
        <div style={{ width: 28, height: 28, borderRadius: 14, background: "rgba(0,0,0,0.25)", display: "flex", alignItems: "center", justifyContent: "center", color: A.fg2 }}>
          <IArrowUp size={14} />
        </div>
      </div>
      <div style={{ fontFamily: F.ui, fontSize: 13, color: A.fg3, margin: "30px 0 6px 10px" }}>Needs you now</div>
      {QUEUE.slice(0, 5).map((r, i) => (
        <RowView key={r.name} r={r} appear={ease.snap(clamp((t - 10 - i * 5) / 20))} />
      ))}
    </div>
  </div>
);

const Queue: React.FC<{ t: number; select: number; inspector: number }> = ({ t, select, inspector }) => {
  const listRight = INSPECTOR * inspector;
  return (
    <div style={{ position: "absolute", left: SIDEBAR, right: 0, top: 81, bottom: 0, overflow: "hidden" }}>
      <div style={{ position: "absolute", left: 32, top: 26, fontFamily: F.display, fontSize: 32, fontWeight: 500, color: A.fg1, letterSpacing: -0.6 }}>Reply queue</div>
      <div
        style={{
          position: "absolute",
          left: 32,
          top: 78,
          display: "flex",
          padding: 3,
          borderRadius: 9,
          background: "rgba(0,0,0,0.14)",
          border: `1px solid ${A.border1}`,
          fontFamily: F.ui,
          fontSize: 14,
        }}
      >
        {[
          ["On me", 12],
          ["On them", 8],
          ["Quiet", 31],
        ].map(([l, n], i) => (
          <span key={l} style={{ padding: "4px 12px", borderRadius: 6, background: i === 0 ? A.bg3 : "transparent", color: i === 0 ? A.fg1 : A.fg2, fontWeight: 600 }}>
            {l} <span style={{ color: A.fg3, fontWeight: 500, marginLeft: 3 }}>{n}</span>
          </span>
        ))}
      </div>
      <div style={{ position: "absolute", right: 22 + listRight, top: 80, display: "flex", gap: 10, fontFamily: F.ui, fontSize: 13.5, color: A.fg2 }}>
        <span style={{ display: "flex", alignItems: "center", gap: 6, padding: "5px 11px", borderRadius: 8, border: `1px solid ${A.border2}`, background: "rgba(255,255,255,0.03)", fontWeight: 600 }}>
          <IArrowDown size={13} /> Newest
        </span>
        <span style={{ display: "flex", alignItems: "center", gap: 7, width: 200 - inspector * 60, padding: "5px 11px", borderRadius: 8, border: `1px solid ${A.border2}`, background: "rgba(255,255,255,0.03)", color: A.fg3 }}>
          <ISearch size={13} /> Search
        </span>
      </div>
      <div style={{ position: "absolute", left: 18, right: 18 + listRight, top: 138 }}>
        {QUEUE.map((r, i) => (
          <RowView key={r.name} r={r} appear={ease.snap(clamp((t - i * 3) / 18))} selected={i === 0 ? select : 0} />
        ))}
      </div>
      <Inspector p={inspector} t={t} />
    </div>
  );
};

const Inspector: React.FC<{ p: number; t: number }> = ({ p }) => {
  if (p <= 0) return null;
  const r = QUEUE[0];
  const Section: React.FC<{ children: React.ReactNode }> = ({ children }) => (
    <div style={{ padding: "16px 28px", borderBottom: `1px solid ${A.border1}` }}>{children}</div>
  );
  return (
    <div
      style={{
        position: "absolute",
        top: 0,
        bottom: 0,
        right: 0,
        width: INSPECTOR,
        transform: `translateX(${(1 - p) * INSPECTOR}px)`,
        background: A.bg3,
        borderLeft: `1px solid ${A.border1}`,
        fontFamily: F.ui,
        color: A.fg1,
      }}
    >
      <div style={{ position: "absolute", right: 20, top: 18, color: A.fg2 }}>
        <IClose size={16} />
      </div>
      <Section>
        <span style={{ fontSize: 11, fontWeight: 700, letterSpacing: 0.8, color: A.warning, background: "rgba(217,155,45,0.14)", border: "1px solid rgba(217,155,45,0.35)", padding: "3px 8px", borderRadius: 7 }}>ON ME</span>
        <div style={{ fontFamily: F.display, fontSize: 24, fontWeight: 500, marginTop: 12 }}>{r.name}</div>
        <div style={{ fontSize: 14, color: A.fg2, marginTop: 6 }}>Telegram · {r.time}</div>
      </Section>
      <Section>
        <Eyebrow>SUGGESTED ACTION</Eyebrow>
        <div style={{ marginTop: 10, padding: "10px 14px", borderRadius: 10, background: A.bg4, border: `1px solid ${A.border2}`, fontSize: 14 }}>{r.sub}</div>
      </Section>
      <Section>
        <Eyebrow>ASSIST</Eyebrow>
        <div style={{ display: "flex", gap: 8, marginTop: 10, fontSize: 13, fontWeight: 600 }}>
          {[
            [ISparkle, "Catch me up"],
            [IBubble, "Suggest replies"],
          ].map(([Icon, l]) => {
            const I = Icon as typeof ISparkle;
            return (
              <span key={l as string} style={{ display: "flex", alignItems: "center", gap: 6, padding: "6px 11px", borderRadius: 8, border: `1px solid ${A.border2}`, background: "rgba(255,255,255,0.03)" }}>
                <I size={13} /> {l as string}
              </span>
            );
          })}
        </div>
      </Section>
      <Section>
        <div style={{ display: "flex", justifyContent: "space-between" }}>
          <Eyebrow>EVIDENCE</Eyebrow>
          <span style={{ fontFamily: F.mono, fontSize: 11, color: A.fg3 }}>1 source · 3 context</span>
        </div>
        {[
          ["Aman Verma", "Sep 24", "can you send the wallet? we sign today", false],
          ["You", "Sep 24", "yes, sending tonight", true],
          ["Aman Verma", "Sep 25", "bumping this — need it before the call", false],
        ].map(([n, d, m, you], i) => (
          <div key={i} style={{ marginTop: 12, paddingLeft: 12, borderLeft: `2px solid ${i === 2 ? A.accent : A.border2}` }}>
            <div style={{ display: "flex", alignItems: "center", gap: 7 }}>
              <Avatar name={n as string} size={16} color={you ? A.av[1] : A.av[4]} />
              <span style={{ fontSize: 13.5, fontWeight: 600 }}>{n}</span>
              <span style={{ fontFamily: F.mono, fontSize: 11, color: A.fg3 }}>{d}</span>
            </div>
            <div style={{ fontSize: 13.5, color: A.fg2, marginTop: 3 }}>{m}</div>
          </div>
        ))}
      </Section>
      <div style={{ position: "absolute", left: 20, right: 20, bottom: 16 }}>
        <div style={{ display: "flex", alignItems: "center", justifyContent: "center", gap: 8, height: 34, borderRadius: 9, background: A.bg4, border: `1px solid ${A.border2}`, fontSize: 13.5, fontWeight: 600 }}>
          <IPlane size={13} /> Open in Telegram
        </div>
      </div>
    </div>
  );
};

export const DashboardWindow: React.FC<{ t: number; page: "home" | "queue"; pageMix: number; select: number; inspector: number; queueT: number }> = ({
  t,
  page,
  pageMix,
  select,
  inspector,
  queueT,
}) => (
  <div
    style={{
      position: "relative",
      width: WIN_W,
      height: WIN_H,
      borderRadius: 12,
      overflow: "hidden",
      background: A.bg2,
      border: `1px solid ${A.border3}`,
      boxShadow: "0 40px 120px rgba(0,0,0,0.45), 0 0 0 0.5px rgba(0,0,0,0.6)",
    }}
  >
    <Sidebar page={page} />
    <Header title={page === "home" ? "Home" : "Reply queue"} sub={page === "home" ? "Your brief from Pidgy" : "Chats that need attention"} />
    <div style={{ opacity: page === "home" ? 1 : 1 - pageMix }}>{page === "home" && <Home t={t} />}</div>
    {page === "queue" && (
      <div style={{ opacity: pageMix }}>
        <Queue t={queueT} select={select} inspector={inspector} />
      </div>
    )}
  </div>
);
