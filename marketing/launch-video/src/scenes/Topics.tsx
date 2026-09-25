import React from "react";
import { useCurrentFrame } from "remotion";
import { clamp, ease, lerp, pulse, prog, rnd } from "../fx/easing";
import { C, FONT } from "../theme";
import { FeatureFrame } from "../ui/FeatureFrame";
import { Glyph } from "../ui/Glyph";
import { Avatar, Chip, Window } from "../ui/Window";
import { BEAT, SCENES, type ChannelId } from "../timeline";

const NODES: { name: string; ch: ChannelId; label: string }[] = [
  { name: "Nova Labs", ch: "telegram", label: "Nova Labs · BD" },
  { name: "Partner Ops", ch: "slack", label: "#partnerships" },
  { name: "Priya Shah", ch: "gmail", label: "Priya (Orbit)" },
  { name: "Dmitri Volkov", ch: "whatsapp", label: "Dmitri" },
  { name: "Founders Chat", ch: "telegram", label: "Founders Chat" },
  { name: "Growth Team", ch: "slack", label: "#growth" },
  { name: "Sara Lin", ch: "gmail", label: "Sara @ Helix" },
  { name: "Kenji Mori", ch: "telegram", label: "Kenji" },
];

const CX = 360;
const CY = 330;

export const Topics: React.FC = () => {
  const frame = useCurrentFrame();
  const dur = SCENES.topics.dur;
  const spin = frame * 0.0025;
  const cardAt = BEAT * 6;
  const card = ease.snap(clamp((frame - cardAt) / 26));
  const beatPulse = pulse(frame, Math.floor(frame / BEAT) * BEAT, 8);

  const pos = NODES.map((_, i) => {
    const a = (i / NODES.length) * Math.PI * 2 + spin - Math.PI / 2;
    const r = 230 + (i % 2) * 40;
    return { x: CX + Math.cos(a) * r * 1.15, y: CY + Math.sin(a) * r * 0.92 };
  });

  return (
    <FeatureFrame
      id="topics"
      dur={dur}
      index="02"
      eyebrow="TOPIC SEARCH"
      title={["See the whole", "conversation."]}
      sub="Chats cluster by project, company, or deal, whichever app they happened in."
      aurora={["rgba(106,61,232,0.45)", "rgba(79,127,220,0.35)"]}
    >
      <Window width={1000} height={680} title="Topics">
        <div style={{ position: "relative", height: 636 }}>
          <svg width={1000} height={636} style={{ position: "absolute", inset: 0 }}>
            {NODES.map((_, i) => {
              const at = BEAT * 2 + i * 7;
              const p = ease.inOutCubic(clamp((frame - at) / 18));
              const { x, y } = pos[i];
              return (
                <line
                  key={i}
                  x1={CX}
                  y1={CY}
                  x2={lerp(CX, x, p)}
                  y2={lerp(CY, y, p)}
                  stroke={i % 2 ? C.accentFg : C.accent}
                  strokeOpacity={0.55 + pulse(frame, at + 18, 10) * 0.45}
                  strokeWidth={2 + pulse(frame, at + 18, 10) * 3}
                />
              );
            })}
            {NODES.map((_, i) => {
              const j = (i + 1) % NODES.length;
              const p = prog(frame, BEAT * 5 + i * 3, 20);
              return (
                <line
                  key={`r${i}`}
                  x1={pos[i].x}
                  y1={pos[i].y}
                  x2={lerp(pos[i].x, pos[j].x, p)}
                  y2={lerp(pos[i].y, pos[j].y, p)}
                  stroke="rgba(255,255,255,0.12)"
                  strokeWidth={1.5}
                  strokeDasharray="4 6"
                />
              );
            })}
          </svg>
          {NODES.map((n, i) => {
            const at = BEAT * 0.6 + i * 5;
            const p = ease.snap(clamp((frame - at) / 34));
            const sx = rnd(`tn${i}x`, -500, 1500);
            const sy = rnd(`tn${i}y`, -400, 1000);
            const x = lerp(sx, pos[i].x, p);
            const y = lerp(sy, pos[i].y, p);
            return (
              <div
                key={i}
                style={{
                  position: "absolute",
                  left: x,
                  top: y,
                  transform: `translate(-50%,-50%) scale(${0.4 + p * 0.6})`,
                  opacity: clamp(p * 2),
                  display: "flex",
                  flexDirection: "column",
                  alignItems: "center",
                  gap: 8,
                }}
              >
                <div style={{ position: "relative" }}>
                  <Avatar name={n.name} size={66} color={C.av[i % C.av.length]} style={{ boxShadow: "0 10px 24px rgba(0,0,0,0.5)" }} />
                  <div style={{ position: "absolute", right: -6, bottom: -4 }}>
                    <Glyph id={n.ch} size={28} tile style={{ boxShadow: `0 0 0 3px ${C.bg0}` }} />
                  </div>
                </div>
                <div style={{ fontSize: 16, fontWeight: 600, color: C.fg2, whiteSpace: "nowrap" }}>{n.label}</div>
              </div>
            );
          })}
          <div
            style={{
              position: "absolute",
              left: CX,
              top: CY,
              transform: `translate(-50%,-50%) scale(${ease.outBack(clamp(frame / 22)) * (1 + beatPulse * 0.05)})`,
              background: `linear-gradient(135deg, ${C.accent}, ${C.violet})`,
              padding: "18px 30px",
              borderRadius: 999,
              fontFamily: FONT.display,
              fontSize: 38,
              fontWeight: 500,
              color: "white",
              whiteSpace: "nowrap",
              boxShadow: `0 0 ${60 + beatPulse * 50}px rgba(79,127,220,0.7), 0 20px 40px rgba(0,0,0,0.4)`,
            }}
          >
            First Dollar
          </div>
          <div
            style={{
              position: "absolute",
              right: 26,
              top: 26,
              width: 300,
              background: C.bg2,
              border: `1px solid ${C.border2}`,
              borderRadius: 16,
              padding: 20,
              transform: `translateX(${(1 - card) * 360}px)`,
              opacity: card,
              boxShadow: "0 30px 60px rgba(0,0,0,0.5)",
            }}
          >
            <div style={{ fontSize: 13, letterSpacing: 1.5, color: C.fg3, fontWeight: 700 }}>TOPIC</div>
            <div style={{ fontFamily: FONT.display, fontSize: 30, marginTop: 4 }}>First Dollar</div>
            <div style={{ display: "flex", gap: 8, marginTop: 12, flexWrap: "wrap" }}>
              <Chip>8 chats</Chip>
              <Chip color={C.success} bg="rgba(78,190,122,0.14)">
                4 sources
              </Chip>
            </div>
            {["Pricing locked at $49", "Nova wants a pilot in Oct", "Deck v3 shared in #growth"].map((t, i) => (
              <div
                key={i}
                style={{
                  marginTop: 14,
                  fontSize: 16,
                  color: C.fg2,
                  paddingLeft: 12,
                  borderLeft: `2px solid ${C.accent}`,
                  opacity: prog(frame, cardAt + 14 + i * 6, 14),
                }}
              >
                {t}
              </div>
            ))}
          </div>
        </div>
      </Window>
    </FeatureFrame>
  );
};
