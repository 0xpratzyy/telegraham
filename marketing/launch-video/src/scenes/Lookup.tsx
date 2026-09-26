import React from "react";
import { useCurrentFrame } from "remotion";
import { clamp, ease, kick, lerp, pulse, prog } from "../fx/easing";
import { C, FONT } from "../theme";
import { FeatureFrame } from "../ui/FeatureFrame";
import { Glyph } from "../ui/Glyph";
import { Chip, Window } from "../ui/Window";
import { BEAT, CHANNEL_ORDER, LOOKUP_QUERY, SCENES, lookupCharFrame, type ChannelId } from "../timeline";

const WALLET = "0x7a3F…c91E";
const RESULTS: { ch: ChannelId; title: string; pre: string; post: string; when: string }[] = [
  { ch: "telegram", title: "Nova Labs · BD", pre: "You: here's our treasury wallet → ", post: "", when: "Tue" },
  { ch: "slack", title: "#partnerships", pre: "You: grant payout goes to ", post: " 🙏", when: "Aug 12" },
  { ch: "whatsapp", title: "Dmitri", pre: "You: sending to ", post: " now", when: "Aug 3" },
  { ch: "gmail", title: "Re: Invoice — Nova Q3", pre: "Payment address: ", post: "", when: "Jul 28" },
];

export const Lookup: React.FC = () => {
  const frame = useCurrentFrame();
  const dur = SCENES.lookup.dur;
  const abs = frame + SCENES.lookup.from;
  const typed = LOOKUP_QUERY.split("").filter((_, i) => abs >= lookupCharFrame(i)).length;
  const resultsAt = BEAT * 4;
  const selectAt = BEAT * 7;
  const sel = prog(frame, selectAt, 24);
  const zoom = lerp(1, 1.16, prog(frame, selectAt, 50, ease.snap));
  const toast = ease.outBack(clamp((frame - selectAt - 18) / 16));

  return (
    <FeatureFrame
      id="lookup"
      dur={dur}
      index="01"
      eyebrow="EXACT LOOKUP"
      title={["Find the", "exact thing."]}
      sub="Wallets, links, contracts, handles. Pidgy finds what you sent, across every chat."
      aurora={["rgba(79,127,220,0.5)", "rgba(42,171,238,0.3)"]}
    >
      <div style={{ transform: `scale(${zoom})`, transformOrigin: "50% 30%" }}>
        <Window width={1000} title="Pidgy  ·  ⌘⇧T" glow={0.6 + pulse(frame, selectAt, 20)}>
          <div style={{ padding: "26px 30px 10px", display: "flex", alignItems: "center", gap: 18 }}>
            <svg width="30" height="30" viewBox="0 0 24 24" fill="none" stroke={C.fg2} strokeWidth="2.2" strokeLinecap="round">
              <circle cx="10.5" cy="10.5" r="6.5" />
              <path d="m20 20-4.8-4.8" />
            </svg>
            <div style={{ fontSize: 34, fontWeight: 500, flex: 1, whiteSpace: "pre", color: C.fg1 }}>
              {typed === 0 ? <span style={{ color: C.fg4 }}>Ask Pidgy anything…</span> : LOOKUP_QUERY.slice(0, typed)}
              <span
                style={{
                  display: "inline-block",
                  width: 3,
                  height: 36,
                  background: C.accent,
                  marginLeft: 3,
                  verticalAlign: "-6px",
                  opacity: Math.floor(frame / 15) % 2 === 0 || typed < LOOKUP_QUERY.length ? 1 : 0,
                }}
              />
            </div>
            <Chip style={{ fontSize: 16, padding: "6px 12px", fontFamily: FONT.mono, transform: `scale(${1 + kick(frame, 20, 8) * 0.3})` }}>
              ⌘⇧T
            </Chip>
          </div>
          <div style={{ display: "flex", gap: 10, padding: "8px 30px 20px", borderBottom: `1px solid ${C.border1}` }}>
            <Chip color="white" bg={C.accent} style={{ fontSize: 15, opacity: prog(frame, 18, 12) }}>
              All sources
            </Chip>
            {CHANNEL_ORDER.map((id, i) => (
              <Chip
                key={id}
                color={C.fg2}
                bg={C.bg2}
                style={{ fontSize: 15, opacity: prog(frame, 22 + i * 3, 12), transform: `translateY(${(1 - prog(frame, 22 + i * 3, 12)) * 10}px)` }}
              >
                <Glyph id={id} size={18} tile /> {id === "whatsapp" ? "WhatsApp" : id[0].toUpperCase() + id.slice(1)}
              </Chip>
            ))}
          </div>
          <div style={{ padding: "12px 16px 20px", minHeight: 470 }}>
            <div style={{ fontSize: 14, color: C.fg3, fontWeight: 600, letterSpacing: 1.5, padding: "8px 14px", opacity: prog(frame, resultsAt - 6, 10) }}>
              4 EXACT MATCHES · MESSAGES YOU SENT
            </div>
            {RESULTS.map((r, i) => {
              const at = resultsAt + i * 6;
              const p = ease.snap(clamp((frame - at) / 22));
              const selected = i === 0 ? sel : 0;
              return (
                <div
                  key={i}
                  style={{
                    display: "flex",
                    alignItems: "center",
                    gap: 18,
                    padding: "18px 16px",
                    borderRadius: 14,
                    marginBottom: 6,
                    background: selected > 0 ? `rgba(79,127,220,${0.16 * selected})` : "transparent",
                    boxShadow: selected > 0 ? `inset 0 0 0 ${2 * selected}px ${C.accentRing}` : "none",
                    opacity: p * (i > 0 ? 1 - sel * 0.45 : 1),
                    transform: `translateY(${(1 - p) * 40}px)`,
                  }}
                >
                  <Glyph id={r.ch} size={46} tile />
                  <div style={{ flex: 1, minWidth: 0 }}>
                    <div style={{ display: "flex", justifyContent: "space-between", fontSize: 21, fontWeight: 600 }}>
                      <span>{r.title}</span>
                      <span style={{ color: C.fg3, fontWeight: 500, fontSize: 17 }}>{r.when}</span>
                    </div>
                    <div style={{ fontSize: 19, color: C.fg2, marginTop: 6, whiteSpace: "nowrap" }}>
                      {r.pre}
                      <span
                        style={{
                          fontFamily: FONT.mono,
                          fontSize: 18,
                          color: i === 0 ? "white" : C.accentFg,
                          background: i === 0 ? `rgba(79,127,220,${0.25 + selected * 0.5})` : C.accentSoft,
                          padding: "2px 8px",
                          borderRadius: 6,
                          boxShadow: i === 0 ? `0 0 ${30 * selected}px rgba(79,127,220,${0.8 * selected})` : "none",
                        }}
                      >
                        {WALLET}
                      </span>
                      {r.post}
                    </div>
                  </div>
                  {i === 0 && (
                    <div style={{ fontSize: 16, color: C.fg3, opacity: sel, fontFamily: FONT.mono }}>↵ jump</div>
                  )}
                </div>
              );
            })}
          </div>
          <div
            style={{
              position: "absolute",
              left: "50%",
              bottom: 30,
              transform: `translateX(-50%) scale(${Math.max(0, toast)})`,
              background: C.success,
              color: "#08140d",
              fontWeight: 700,
              fontSize: 20,
              padding: "12px 22px",
              borderRadius: 999,
              boxShadow: "0 20px 40px rgba(78,190,122,0.35)",
              display: "flex",
              gap: 10,
              alignItems: "center",
            }}
          >
            ✓ Copied {WALLET}
          </div>
        </Window>
      </div>
    </FeatureFrame>
  );
};
