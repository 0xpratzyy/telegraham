import React from "react";
import { useCurrentFrame } from "remotion";
import { clamp, ease, pulse, prog } from "../fx/easing";
import { C, CHANNEL, FONT } from "../theme";
import { FeatureFrame } from "../ui/FeatureFrame";
import { Glyph } from "../ui/Glyph";
import { Window } from "../ui/Window";
import { BEAT, CHANNEL_ORDER, RECAP_CHECKS, SCENES, type ChannelId } from "../timeline";

const STATS = [
  { label: "Replies on you", value: 12, color: C.danger },
  { label: "Open tasks", value: 7, color: C.warning },
  { label: "Active topics", value: 23, color: C.accentFg },
];
const SHARE: Record<ChannelId, number> = { telegram: 0.46, slack: 0.24, gmail: 0.18, whatsapp: 0.12 };
const TASKS: { ch: ChannelId; text: string }[] = [
  { ch: "telegram", text: "Send Nova the signed deck" },
  { ch: "slack", text: "Answer #partnerships launch thread" },
  { ch: "gmail", text: "Approve Q3 invoice for Sara" },
  { ch: "whatsapp", text: "Confirm call time with Dmitri" },
];

const Donut: React.FC<{ p: number }> = ({ p }) => {
  const R = 92;
  const circ = 2 * Math.PI * R;
  let acc = 0;
  return (
    <svg width={240} height={240} viewBox="0 0 240 240">
      <circle cx="120" cy="120" r={R} fill="none" stroke={C.bg3} strokeWidth={26} />
      {CHANNEL_ORDER.map((id) => {
        const share = SHARE[id];
        const start = acc;
        acc += share;
        const visible = Math.max(0, Math.min(share, p - start));
        return (
          <circle
            key={id}
            cx="120"
            cy="120"
            r={R}
            fill="none"
            stroke={id === "slack" ? "#E01E5A" : CHANNEL[id].tint}
            strokeWidth={26}
            strokeDasharray={`${Math.max(0, visible * circ - 3)} ${circ}`}
            strokeDashoffset={-start * circ}
            transform="rotate(-90 120 120)"
          />
        );
      })}
    </svg>
  );
};

export const Recap: React.FC = () => {
  const frame = useCurrentFrame();
  const dur = SCENES.recap.dur;
  const donut = ease.inOutCubic(clamp((frame - BEAT * 3) / (BEAT * 2)));

  return (
    <FeatureFrame
      id="recap"
      dur={dur}
      index="04"
      eyebrow="DAILY RECAP"
      title={["Start the day", "clear."]}
      sub="One dashboard for what matters today, before you open a single app."
      aurora={["rgba(78,190,122,0.25)", "rgba(79,127,220,0.45)"]}
    >
      <Window width={1000} height={740} title="Dashboard">
        <div style={{ padding: "28px 34px" }}>
          <div style={{ fontFamily: FONT.mono, fontSize: 15, letterSpacing: 3, color: C.fg3, opacity: prog(frame, 8, 14) }}>FRIDAY · 9:02 AM</div>
          <div style={{ fontFamily: FONT.display, fontSize: 50, fontWeight: 500, letterSpacing: -1, marginTop: 6, opacity: prog(frame, 12, 20), transform: `translateY(${(1 - prog(frame, 12, 20)) * 20}px)` }}>
            What to do now
          </div>
          <div style={{ display: "flex", gap: 18, marginTop: 24 }}>
            {STATS.map((s, i) => {
              const at = 26 + i * 8;
              const p = ease.snap(clamp((frame - at) / 26));
              const n = Math.round(s.value * ease.outCubic(clamp((frame - at) / 50)));
              return (
                <div
                  key={i}
                  style={{
                    flex: 1,
                    background: C.bg2,
                    border: `1px solid ${C.border2}`,
                    borderRadius: 16,
                    padding: "18px 22px",
                    opacity: p,
                    transform: `translateY(${(1 - p) * 40}px) scale(${1 + pulse(frame, at + 50, 10) * 0.04})`,
                  }}
                >
                  <div style={{ fontSize: 15, color: C.fg3, fontWeight: 600 }}>{s.label}</div>
                  <div style={{ fontFamily: FONT.display, fontSize: 64, lineHeight: 1.05, color: s.color, fontVariantNumeric: "tabular-nums" }}>{n}</div>
                </div>
              );
            })}
          </div>
          <div style={{ display: "flex", gap: 24, marginTop: 22 }}>
            <div
              style={{
                width: 360,
                background: C.bg2,
                border: `1px solid ${C.border2}`,
                borderRadius: 16,
                padding: 18,
                display: "flex",
                flexDirection: "column",
                alignItems: "center",
                opacity: prog(frame, BEAT * 2.5, 20),
              }}
            >
              <div style={{ alignSelf: "flex-start", fontSize: 15, color: C.fg3, fontWeight: 600 }}>Attention by source</div>
              <div style={{ position: "relative", marginTop: 4 }}>
                <Donut p={donut} />
                <div style={{ position: "absolute", inset: 0, display: "flex", alignItems: "center", justifyContent: "center", flexDirection: "column" }}>
                  <div style={{ fontFamily: FONT.display, fontSize: 44 }}>{Math.round(42 * donut)}</div>
                  <div style={{ fontSize: 13, color: C.fg3 }}>threads</div>
                </div>
              </div>
              <div style={{ display: "flex", gap: 12, marginTop: 6 }}>
                {CHANNEL_ORDER.map((id, i) => (
                  <div key={id} style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 14, color: C.fg2, opacity: prog(frame, BEAT * 3 + i * 8, 12) }}>
                    <Glyph id={id} size={18} tile />
                    {Math.round(SHARE[id] * 100)}%
                  </div>
                ))}
              </div>
            </div>
            <div style={{ flex: 1, background: C.bg2, border: `1px solid ${C.border2}`, borderRadius: 16, padding: "18px 20px", opacity: prog(frame, BEAT * 3, 20) }}>
              <div style={{ fontSize: 15, color: C.fg3, fontWeight: 600, marginBottom: 8 }}>Today's tasks</div>
              {TASKS.map((t, i) => {
                const at = RECAP_CHECKS[i] - SCENES.recap.from;
                const done = ease.outBack(clamp((frame - at) / 12));
                const rowIn = prog(frame, BEAT * 3 + 6 + i * 6, 18);
                return (
                  <div
                    key={i}
                    style={{
                      display: "flex",
                      alignItems: "center",
                      gap: 14,
                      padding: "13px 6px",
                      borderBottom: i < TASKS.length - 1 ? `1px solid ${C.border1}` : "none",
                      opacity: rowIn * (1 - clamp(done) * 0.45),
                      transform: `translateX(${(1 - rowIn) * 30}px)`,
                    }}
                  >
                    <div
                      style={{
                        width: 26,
                        height: 26,
                        borderRadius: 13,
                        border: `2px solid ${done > 0 ? C.success : C.fg4}`,
                        background: done > 0 ? C.success : "transparent",
                        display: "flex",
                        alignItems: "center",
                        justifyContent: "center",
                        color: "#08140d",
                        fontWeight: 900,
                        fontSize: 16,
                        transform: `scale(${1 + pulse(frame, at, 6) * 0.35})`,
                        boxShadow: `0 0 ${pulse(frame, at, 10) * 30}px ${C.success}`,
                      }}
                    >
                      <span style={{ transform: `scale(${Math.max(0, done)})` }}>✓</span>
                    </div>
                    <Glyph id={t.ch} size={24} tile />
                    <span style={{ fontSize: 18, position: "relative" }}>
                      {t.text}
                      <span
                        style={{
                          position: "absolute",
                          left: 0,
                          top: "52%",
                          height: 2,
                          width: `${clamp(done) * 100}%`,
                          background: C.fg2,
                        }}
                      />
                    </span>
                  </div>
                );
              })}
            </div>
          </div>
        </div>
      </Window>
    </FeatureFrame>
  );
};
