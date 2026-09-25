import React from "react";
import { AbsoluteFill, useCurrentFrame } from "remotion";
import { clamp, ease, rnd } from "../fx/easing";
import { env } from "../fx/track";
import { C, FONT } from "../theme";
import { Avatar, Badge } from "../ui/Chat";
import { Line } from "../ui/Type";
import { s } from "../timeline";

const NAMES = [
  "Nova Labs <> Pidgy", "ETH Denver side events", "BD pipeline", "Founders only", "Mom", "gm frens", "Design crit",
  "Aman", "Akhil", "Investor updates", "Kenji", "Priya", "Base builders", "Hackathon judges", "Sara", "Growth team",
  "Solana summer", "Recruiting", "Dmitri", "Weekend plans", "Launch war room", "Angel syndicate", "Ops", "Lena",
];
const MSGS = [
  "sounds good, lmk", "who's coming tonight?", "bumping this", "ok", "call me when free", "gm", "deck v3 attached",
  "did anyone see the thread?", "haha yes", "can we move to 4?", "sent", "link?", "on it", "+1", "thoughts?",
  "will check tomorrow", "voice message", "photo", "left the group", "any update?",
];

const ROW_H = 100;
const ROWS = 48;
const TARGET = 40;
const BASE_Y = 560;
const REST_Y = 690;
const SCROLL_END = BASE_Y + TARGET * ROW_H + ROW_H / 2 - REST_Y;

const scrollAt = (f: number) => {
  const run = SCROLL_END * ease.inOutCubic(clamp((f - s(2.4)) / (s(7) - s(2.4))));
  const after = ease.inOutCubic(clamp((f - s(9.4)) / s(2.4))) * 520;
  return run + after;
};

export const Opening: React.FC = () => {
  const frame = useCurrentFrame();
  const scroll = scrollAt(frame);
  const speed = Math.abs(scrollAt(frame + 1) - scroll);
  const listIn = env(frame, s(2.4), 1e9, 40);
  const focus = env(frame, s(6.9), s(9.3), 24, 40);
  const passed = ease.inOutCubic(clamp((frame - s(9.4)) / 30));
  const fadeOut = ease.inOutCubic(clamp((frame - s(11.4)) / s(0.6)));

  return (
    <AbsoluteFill style={{ background: C.page }}>
      <AbsoluteFill
        style={{
          opacity: listIn * 0.9,
          maskImage: "linear-gradient(to bottom, transparent 0%, transparent 42%, black 56%, black 86%, transparent 100%)",
          WebkitMaskImage: "linear-gradient(to bottom, transparent 0%, transparent 42%, black 56%, black 86%, transparent 100%)",
          filter: speed > 2 ? `blur(${Math.min(7, speed * 0.09)}px)` : undefined,
        }}
      >
        {Array.from({ length: ROWS }, (_, i) => {
          const y = BASE_Y + i * ROW_H - scroll;
          if (y < 300 || y > 1100) return null;
          const isTarget = i === TARGET;
          const name = isTarget ? "stuff" : NAMES[i % NAMES.length];
          const msg = isTarget ? "Aman: can you send the wallet? we sign today" : MSGS[Math.floor(rnd(`m${i}`) * MSGS.length)];
          const unread = isTarget ? 0 : 1 + Math.floor(rnd(`u${i}`) * 40);
          const hi = isTarget ? focus : 0;
          const dimOthers = !isTarget ? 1 - focus * 0.55 : 1;
          return (
            <div
              key={i}
              style={{
                position: "absolute",
                left: 960 - 470,
                top: y,
                width: 940,
                height: ROW_H - 12,
                boxSizing: "border-box",
                display: "flex",
                alignItems: "center",
                gap: 20,
                padding: "0 24px",
                borderRadius: 18,
                background: hi > 0 ? `rgba(66,66,66,${0.4 + hi * 0.5})` : "transparent",
                border: `1px solid ${hi > 0 ? `rgba(234,140,50,${0.45 * hi * (1 - passed)})` : "transparent"}`,
                transform: `scale(${1 + hi * 0.05})`,
                opacity: dimOthers * (isTarget ? 1 - passed * 0.5 : 1),
                fontFamily: FONT.ui,
                color: C.fg1,
              }}
            >
              <Avatar name={name} size={56} color={isTarget ? C.bg4 : C.av[i % C.av.length]} />
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
                  <span style={{ fontSize: 24, fontWeight: 600 }}>{name}</span>
                  {isTarget && (
                    <span style={{ opacity: hi * (1 - passed) }}>
                      <Badge who="me" size={14} />
                    </span>
                  )}
                  <span style={{ marginLeft: "auto", fontSize: 18, color: C.fg3 }}>
                    {isTarget ? (passed > 0.5 ? "2w" : "3d") : `${1 + (i % 11)}h`}
                  </span>
                </div>
                <div style={{ fontSize: 21, color: C.fg2, marginTop: 4, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{msg}</div>
              </div>
              {unread > 0 && (
                <span
                  style={{
                    minWidth: 30,
                    height: 30,
                    padding: "0 9px",
                    borderRadius: 15,
                    background: C.bg4,
                    color: C.fg2,
                    fontSize: 15,
                    fontWeight: 600,
                    display: "flex",
                    alignItems: "center",
                    justifyContent: "center",
                  }}
                >
                  {unread}
                </span>
              )}
            </div>
          );
        })}
      </AbsoluteFill>

      <AbsoluteFill style={{ alignItems: "center", paddingTop: 200 }}>
        <div style={{ position: "relative", width: 1600, height: 260 }}>
          <Abs>
            <Line text="1,571 contacts." inAt={s(0.3)} outAt={s(1.9)} size={104} />
          </Abs>
          <Abs>
            <Line text="A forty-screen inbox." inAt={s(2.0)} outAt={s(4.3)} size={104} />
          </Abs>
          <Abs>
            <Line text="The reply that mattered most" inAt={s(4.5)} outAt={s(9.2)} size={84} />
            <Line text="was buried in a group called “stuff.”" inAt={s(5.1)} outAt={s(9.2)} size={84} italic />
          </Abs>
          <Abs>
            <Line text="The moment had passed." inAt={s(9.4)} outAt={s(11.4)} size={104} color={C.fg2} />
          </Abs>
        </div>
      </AbsoluteFill>
      <AbsoluteFill style={{ background: "black", opacity: fadeOut }} />
    </AbsoluteFill>
  );
};

const Abs: React.FC<{ children: React.ReactNode }> = ({ children }) => (
  <div style={{ position: "absolute", inset: 0, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "flex-start" }}>
    {children}
  </div>
);