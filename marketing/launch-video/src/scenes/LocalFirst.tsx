import React from "react";
import { AbsoluteFill, useCurrentFrame } from "remotion";
import { Aurora, MascotImg } from "../fx/Overlays";
import { SplitText } from "../fx/SplitText";
import { Whip } from "../fx/Whip";
import { clamp, ease, lerp, pulse, prog, rnd } from "../fx/easing";
import { C, CHANNEL, FONT } from "../theme";
import { Glyph } from "../ui/Glyph";
import { BEAT, CHANNEL_ORDER, LOCK_SNAP, SCENES } from "../timeline";

// Screen interior in laptop-local coordinates.
const SX = 90;
const SY = 70;
const SW = 720;
const SH = 440;
const CORE = { x: SX + SW / 2, y: SY + SH / 2 };

const tri = (t: number) => {
  const m = ((t % 2) + 2) % 2;
  return m < 1 ? m : 2 - m;
};

export const LocalFirst: React.FC = () => {
  const frame = useCurrentFrame();
  const dur = SCENES.local.dur;
  const snap = LOCK_SNAP - SCENES.local.from;
  const draw = ease.inOutCubic(clamp((frame - 10) / 70));
  const core = ease.outBack(clamp((frame - 60) / 24));
  const lockIn = ease.snap(clamp((frame - (snap - 40)) / 30));
  const shackle = frame < snap ? -34 * lockIn : lerp(-34, 0, ease.outBack(clamp((frame - snap) / 10)));
  const lockToBadge = ease.snap(clamp((frame - (snap + 60)) / 40));
  const beatPulse = pulse(frame, Math.floor(frame / BEAT) * BEAT, 10);
  const snapFlash = pulse(frame, snap, 12);

  const glyphPos = [
    { x: SX + 90, y: SY + 80 },
    { x: SX + SW - 90, y: SY + 80 },
    { x: SX + 90, y: SY + SH - 80 },
    { x: SX + SW - 90, y: SY + SH - 80 },
  ];

  const bounces: { x: number; y: number; age: number }[] = [];
  const escapees = Array.from({ length: 7 }, (_, i) => {
    const vx = rnd(`esx${i}`, -1, 1) * 0.006;
    const vy = rnd(`esy${i}`, -1, 1) * 0.009;
    const t0 = rnd(`est${i}`, 0, 2);
    const tx = t0 + frame * Math.abs(vx) * 2 + 0.002 * frame;
    const ty = t0 * 1.3 + frame * Math.abs(vy) * 2;
    const x = SX + 14 + tri(tx) * (SW - 28);
    const y = SY + 14 + tri(ty) * (SH - 28);
    const edgeX = Math.min(tri(tx), 1 - tri(tx));
    const edgeY = Math.min(tri(ty), 1 - tri(ty));
    if (edgeX < 0.015 || edgeY < 0.02) bounces.push({ x, y, age: 0 });
    return { x, y };
  });

  return (
    <AbsoluteFill style={{ background: C.void }}>
      <Aurora colors={["rgba(63,224,197,0.22)", "rgba(79,127,220,0.4)"]} opacity={0.6} seed="local" speed={0.6} />
      <Whip id="local" dur={dur}>
        <AbsoluteFill style={{ flexDirection: "row", alignItems: "center", padding: "0 90px" }}>
          <div style={{ width: 900, height: 640, position: "relative", flex: "none", transform: `scale(${1 + frame * 0.00015})` }}>
            <svg width={900} height={640} style={{ position: "absolute", inset: 0, overflow: "visible" }}>
              <defs>
                <filter id="glowLine" x="-20%" y="-20%" width="140%" height="140%">
                  <feGaussianBlur stdDeviation="6" result="b" />
                  <feMerge>
                    <feMergeNode in="b" />
                    <feMergeNode in="SourceGraphic" />
                  </feMerge>
                </filter>
              </defs>
              <rect
                x={SX - 22}
                y={SY - 22}
                width={SW + 44}
                height={SH + 44}
                rx={26}
                fill="rgba(20,22,28,0.85)"
                stroke="rgba(255,255,255,0.75)"
                strokeWidth={3}
                pathLength={1}
                strokeDasharray={1}
                strokeDashoffset={1 - draw}
              />
              <rect
                x={SX}
                y={SY}
                width={SW}
                height={SH}
                rx={10}
                fill="rgba(79,127,220,0.05)"
                stroke={C.accent}
                strokeWidth={2 + beatPulse * 2 + snapFlash * 6}
                strokeOpacity={draw * (0.5 + beatPulse * 0.3 + snapFlash * 0.5)}
                filter="url(#glowLine)"
              />
              <path
                d={`M ${SX - 110} ${SY + SH + 40} L ${SX + SW + 110} ${SY + SH + 40} L ${SX + SW + 70} ${SY + SH + 70} L ${SX - 70} ${SY + SH + 70} Z`}
                fill="rgba(20,22,28,0.85)"
                stroke="rgba(255,255,255,0.75)"
                strokeWidth={3}
                pathLength={1}
                strokeDasharray={1}
                strokeDashoffset={1 - clamp(draw * 1.4 - 0.4)}
              />
              {CHANNEL_ORDER.map((id, i) => {
                const g = glyphPos[i];
                return Array.from({ length: 5 }, (_, k) => {
                  const t = ((frame * 0.012 + k / 5 + i * 0.13) % 1 + 1) % 1;
                  const mx = (g.x + CORE.x) / 2 + (i % 2 ? 60 : -60);
                  const my = (g.y + CORE.y) / 2 + (i < 2 ? 50 : -50);
                  const x = (1 - t) * (1 - t) * g.x + 2 * (1 - t) * t * mx + t * t * CORE.x;
                  const y = (1 - t) * (1 - t) * g.y + 2 * (1 - t) * t * my + t * t * CORE.y;
                  return (
                    <circle
                      key={`${id}${k}`}
                      cx={x}
                      cy={y}
                      r={8}
                      fill={id === "slack" ? "#E01E5A" : CHANNEL[id].tint}
                      filter="url(#glowLine)"
                      opacity={prog(frame, 90 + i * 8, 20) * Math.sin(t * Math.PI)}
                    />
                  );
                });
              })}
              {Array.from({ length: 36 }, (_, i) => {
                const r = rnd(`orb${i}r`, 90, 190);
                const a = frame * rnd(`orb${i}s`, 0.01, 0.03) + rnd(`orb${i}a`, 0, 6.28);
                return (
                  <circle
                    key={`o${i}`}
                    cx={CORE.x + Math.cos(a) * r * 1.4}
                    cy={CORE.y + Math.sin(a) * r * 0.8}
                    r={rnd(`orb${i}z`, 2.5, 6)}
                    fill={i % 3 ? "rgba(145,172,232,0.8)" : C.teal}
                    opacity={core * 0.8}
                  />
                );
              })}
              {escapees.map((e, i) => (
                <circle key={`e${i}`} cx={e.x} cy={e.y} r={9} fill="white" opacity={prog(frame, 120, 20)} filter="url(#glowLine)" />
              ))}
              {bounces.map((b, i) => (
                <circle key={`b${i}`} cx={b.x} cy={b.y} r={22} fill="none" stroke={C.accentFg} strokeWidth={3} opacity={0.8 * prog(frame, 120, 20)} />
              ))}
            </svg>
            {CHANNEL_ORDER.map((id, i) => {
              const p = ease.outBack(clamp((frame - 80 - i * 6) / 18));
              return (
                <div key={id} style={{ position: "absolute", left: glyphPos[i].x, top: glyphPos[i].y, transform: `translate(-50%,-50%) scale(${p})` }}>
                  <Glyph id={id} size={62} tile style={{ boxShadow: "0 10px 24px rgba(0,0,0,0.5)" }} />
                </div>
              );
            })}
            <div
              style={{
                position: "absolute",
                left: CORE.x,
                top: CORE.y,
                transform: `translate(-50%,-50%) scale(${core * (1 + beatPulse * 0.04)})`,
                borderRadius: 40,
                boxShadow: `0 0 ${60 + beatPulse * 40}px rgba(79,127,220,0.8)`,
              }}
            >
              <MascotImg size={150} radius={0.26} />
            </div>
            <div
              style={{
                position: "absolute",
                left: lerp(CORE.x, SX + SW - 20, lockToBadge),
                top: lerp(CORE.y + 10, SY + 34, lockToBadge),
                transform: `translate(-50%,-50%) scale(${lockIn * lerp(1.6, 0.55, lockToBadge) * (1 + snapFlash * 0.2)})`,
                opacity: lockIn,
              }}
            >
              <svg width="150" height="180" viewBox="0 0 150 180" style={{ overflow: "visible" }}>
                <path
                  d="M40 86 V56 a35 35 0 0 1 70 0 V86"
                  fill="none"
                  stroke="white"
                  strokeWidth={16}
                  strokeLinecap="round"
                  transform={`translate(0 ${shackle})`}
                />
                <rect x="18" y="80" width="114" height="92" rx="22" fill={C.accent} stroke="white" strokeWidth={5} />
                <circle cx="75" cy="118" r="11" fill="white" />
                <rect x="70" y="120" width="10" height="26" rx="5" fill="white" />
              </svg>
            </div>
            <div
              style={{
                position: "absolute",
                left: CORE.x,
                top: CORE.y,
                width: 10,
                height: 10,
                borderRadius: "50%",
                border: `4px solid rgba(145,172,232,${snapFlash})`,
                transform: `translate(-50%,-50%) scale(${(1 - snapFlash) * 90 + 1})`,
                opacity: frame >= snap ? 1 : 0,
              }}
            />
          </div>
          <div style={{ flex: 1, paddingLeft: 60 }}>
            <div style={{ fontFamily: FONT.mono, fontSize: 20, letterSpacing: 4, color: C.teal, opacity: prog(frame, 70, 20) }}>05 —— PRIVATE BY DESIGN</div>
            <div style={{ fontFamily: FONT.display, fontSize: 124, fontWeight: 500, letterSpacing: -4, lineHeight: 1, marginTop: 20, color: "white" }}>
              <SplitText text="Local-first." start={80} stagger={2} dur={28} />
            </div>
            <div
              style={{
                fontFamily: FONT.ui,
                fontSize: 36,
                color: C.fg1,
                marginTop: 24,
                lineHeight: 1.3,
                opacity: prog(frame, 120, 24),
                transform: `translateY(${(1 - prog(frame, 120, 24)) * 20}px)`,
              }}
            >
              Your messages stay on your Mac.
            </div>
            <div style={{ marginTop: 40, display: "flex", flexDirection: "column", gap: 16 }}>
              {["On-device semantic search", "No analytics SDK. No tracking.", "Bring your own AI key"].map((t, i) => {
                const p = ease.snap(clamp((frame - snap - 10 - i * 8) / 22));
                return (
                  <div
                    key={t}
                    style={{
                      display: "flex",
                      alignItems: "center",
                      gap: 16,
                      fontFamily: FONT.ui,
                      fontSize: 27,
                      color: C.fg2,
                      opacity: p,
                      transform: `translateX(${(1 - p) * 40}px)`,
                    }}
                  >
                    <span style={{ width: 30, height: 30, borderRadius: 15, background: "rgba(78,190,122,0.18)", color: C.success, display: "inline-flex", alignItems: "center", justifyContent: "center", fontWeight: 800, fontSize: 17 }}>
                      ✓
                    </span>
                    {t}
                  </div>
                );
              })}
            </div>
          </div>
        </AbsoluteFill>
      </Whip>
    </AbsoluteFill>
  );
};
