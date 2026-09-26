import React from "react";
import { useCurrentFrame } from "remotion";
import { clamp, ease, lerp, pulse, prog } from "../fx/easing";
import { C, FONT } from "../theme";
import { FeatureFrame } from "../ui/FeatureFrame";
import { Glyph } from "../ui/Glyph";
import { Avatar, Chip, Window } from "../ui/Window";
import { BEAT, DRAFT_TEXT, SCENES, draftCharFrame, type ChannelId } from "../timeline";

type Card = { name: string; ch: ChannelId; msg: string; chip: string; onYou: boolean; tone: "danger" | "warning" | "muted" };
const CARDS: Card[] = [
  { name: "Priya Shah", ch: "telegram", msg: "Can you send the signed deck + wallet before the call?", chip: "Waiting 2h", onYou: true, tone: "danger" },
  { name: "Partner Ops", ch: "slack", msg: "@you are we good to announce Monday?", chip: "Today", onYou: true, tone: "warning" },
  { name: "Sara Lin", ch: "gmail", msg: "Following up on the Q3 invoice approval", chip: "Today", onYou: true, tone: "warning" },
  { name: "Dmitri Volkov", ch: "whatsapp", msg: "What time works for the call tomorrow?", chip: "1d", onYou: true, tone: "muted" },
  { name: "Kenji Mori", ch: "telegram", msg: "Will send the numbers by EOD 👍", chip: "Their move", onYou: false, tone: "muted" },
  { name: "Growth Team", ch: "slack", msg: "Drafting the launch post, review after", chip: "Their move", onYou: false, tone: "muted" },
];

const CARD_H = 104;
const COL_W = 462;

const toneColor = (t: Card["tone"]) =>
  t === "danger" ? [C.danger, "rgba(214,61,67,0.16)"] : t === "warning" ? [C.warning, "rgba(217,155,45,0.16)"] : [C.fg2, C.bg3];

export const Replies: React.FC = () => {
  const frame = useCurrentFrame();
  const dur = SCENES.replies.dur;
  const abs = frame + SCENES.replies.from;
  const sortAt = BEAT * 5;
  const expandAt = BEAT * 7;
  const expand = ease.snap(clamp((frame - expandAt) / 22));
  const typed = DRAFT_TEXT.split("").filter((_, i) => abs >= draftCharFrame(i)).length;
  const sendAt = draftCharFrame(DRAFT_TEXT.length) - SCENES.replies.from + 6;
  const header = prog(frame, sortAt, 20);

  let onYouIdx = 0;
  let waitIdx = 0;
  const targets = CARDS.map((c) => {
    if (c.onYou) {
      const i = onYouIdx++;
      return { x: 24, y: 70 + i * (CARD_H + 12) + (i > 0 ? expand * 128 : 0) };
    }
    const i = waitIdx++;
    return { x: 24 + COL_W + 28, y: 70 + i * (CARD_H + 12) };
  });

  return (
    <FeatureFrame
      id="replies"
      dur={dur}
      index="03"
      eyebrow="REPLY QUEUE"
      title={["Know what's", "on you."]}
      sub="Pidgy triages who's waiting on you across every app, and drafts the reply in your voice."
      aurora={["rgba(214,61,67,0.28)", "rgba(79,127,220,0.45)"]}
    >
      <Window width={1000} height={740} title="Reply queue">
        <div style={{ position: "relative", height: 696, perspective: 1400 }}>
          <div style={{ position: "absolute", left: 30, top: 22, display: "flex", gap: 12, alignItems: "center", opacity: header }}>
            <span style={{ fontSize: 20, fontWeight: 700 }}>On you</span>
            <Chip>4</Chip>
          </div>
          <div style={{ position: "absolute", left: 30 + COL_W + 28, top: 22, display: "flex", gap: 12, alignItems: "center", opacity: header * 0.7 }}>
            <span style={{ fontSize: 20, fontWeight: 700, color: C.fg2 }}>Waiting on them</span>
            <Chip color={C.fg2} bg={C.bg3}>
              2
            </Chip>
          </div>
          {CARDS.map((c, i) => {
            const n = CARDS.length;
            const shuffleStart = BEAT * 3;
            const sh = clamp((frame - shuffleStart - i * 5) / 12);
            const shArc = Math.sin(sh * Math.PI);
            const fanIn = ease.snap(clamp((frame - 8 - i * 4) / 30));
            const stackX = 260 + (i - n / 2) * 10 + shArc * (i % 2 ? 300 : -300);
            const stackY = 220 - i * 8 + (1 - fanIn) * 500;
            const stackRot = (i - n / 2) * 4 + shArc * (i % 2 ? 10 : -10);
            const s = ease.snap(clamp((frame - sortAt - i * 3) / 30));
            const x = lerp(stackX, targets[i].x, s);
            const y = lerp(stackY, targets[i].y, s);
            const rot = lerp(stackRot, 0, s);
            const flip = Math.sin(s * Math.PI) * (c.onYou ? -40 : 40);
            const isHero = i === 0;
            const h = CARD_H + (isHero ? expand * 128 : 0);
            const [tc, tb] = toneColor(c.tone);
            const sendGlow = isHero ? pulse(frame, sendAt, 14) : 0;
            return (
              <div
                key={i}
                style={{
                  position: "absolute",
                  left: x,
                  top: y,
                  width: COL_W,
                  height: h,
                  transform: `rotate(${rot}deg) rotateY(${flip}deg)`,
                  background: C.bg2,
                  border: `1px solid ${isHero && expand > 0 ? C.accentRing : C.border2}`,
                  borderRadius: 16,
                  padding: "18px 20px",
                  boxSizing: "border-box",
                  boxShadow: `0 ${20 - s * 10}px ${50 - s * 20}px rgba(0,0,0,0.5)`,
                  opacity: fanIn * (c.onYou ? 1 : lerp(1, 0.6, s)),
                  zIndex: s > 0.5 ? 10 - i : i,
                  overflow: "hidden",
                }}
              >
                <div style={{ display: "flex", gap: 14, alignItems: "center" }}>
                  <div style={{ position: "relative" }}>
                    <Avatar name={c.name} size={48} color={C.av[(i * 2) % C.av.length]} />
                    <div style={{ position: "absolute", right: -6, bottom: -4 }}>
                      <Glyph id={c.ch} size={22} tile style={{ boxShadow: `0 0 0 3px ${C.bg2}` }} />
                    </div>
                  </div>
                  <div style={{ flex: 1, minWidth: 0 }}>
                    <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                      <span style={{ fontSize: 19, fontWeight: 650 }}>{c.name}</span>
                      <Chip color={tc} bg={tb} style={{ fontSize: 13 }}>
                        {c.chip}
                      </Chip>
                    </div>
                    <div style={{ fontSize: 16.5, color: C.fg2, marginTop: 5, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
                      {c.msg}
                    </div>
                  </div>
                </div>
                {isHero && (
                  <div style={{ marginTop: 18, opacity: prog(frame, expandAt + 8, 12) }}>
                    <div style={{ fontSize: 12.5, letterSpacing: 1.5, fontWeight: 700, color: C.accentFg, marginBottom: 8 }}>✦ DRAFT · IN YOUR VOICE</div>
                    <div
                      style={{
                        background: C.bg1,
                        border: `1px solid ${C.border2}`,
                        borderRadius: 12,
                        padding: "12px 14px",
                        fontSize: 17,
                        color: C.fg1,
                        display: "flex",
                        alignItems: "center",
                        gap: 10,
                      }}
                    >
                      <span style={{ flex: 1, whiteSpace: "nowrap", overflow: "hidden" }}>
                        {DRAFT_TEXT.slice(0, typed)}
                        <span style={{ display: "inline-block", width: 2, height: 18, background: C.accent, verticalAlign: "-3px", marginLeft: 2 }} />
                      </span>
                      <span
                        style={{
                          background: C.accent,
                          color: "white",
                          fontWeight: 700,
                          fontSize: 14,
                          padding: "6px 12px",
                          borderRadius: 8,
                          fontFamily: FONT.ui,
                          boxShadow: `0 0 ${sendGlow * 40}px ${C.accent}`,
                          transform: `scale(${1 + sendGlow * 0.15})`,
                        }}
                      >
                        Send ↵
                      </span>
                    </div>
                  </div>
                )}
              </div>
            );
          })}
        </div>
      </Window>
    </FeatureFrame>
  );
};
