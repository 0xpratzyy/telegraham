import React from "react";
import { AbsoluteFill, useCurrentFrame } from "remotion";
import { DashboardWindow, WIN_H, WIN_W } from "../app/Dashboard";
import { Cursor } from "../app/Cursor";
import { clamp, ease, lerp } from "../fx/easing";
import { env } from "../fx/track";
import { Line } from "../ui/Type";
import { QUEUE_CLICKS, SCENES, s } from "../timeline";

const S0 = 0.86;
const TL0 = { x: 960 - (WIN_W * S0) / 2, y: 600 - (WIN_H * S0) / 2 };
const S1 = 1.5;
const FOCUS = { x: 872, y: 400 };
const TL1 = { x: 960 - FOCUS.x * S1, y: 540 - FOCUS.y * S1 };
const toScreen = (x: number, y: number) => [TL0.x + x * S0, TL0.y + y * S0] as const;

export const Queue: React.FC = () => {
  const frame = useCurrentFrame();
  const [navClick, rowClick] = QUEUE_CLICKS.map((f) => f - SCENES.queue.from);
  const out = s(8.3);
  const enter = ease.snap(clamp((frame - s(0.35)) / 40));
  const exit = ease.inOutCubic(clamp((frame - out) / 30));
  const zoom = ease.inOutCubic(clamp((frame - s(5.0)) / s(1.1)));
  const S = lerp(S0, S1, zoom);
  const tlx = lerp(TL0.x, TL1.x, zoom);
  const tly = lerp(TL0.y, TL1.y, zoom) + (1 - enter) * 120;
  const page = frame >= navClick ? "queue" : "home";
  const pageMix = clamp((frame - navClick) / 8);
  const select = clamp((frame - rowClick) / 8);
  const inspector = ease.snap(clamp((frame - rowClick - 2) / 24));

  const nav = toScreen(118, 186);
  const row = toScreen(640, 246);

  return (
    <AbsoluteFill>
      <div style={{ position: "absolute", left: 0, right: 0, top: 58 }}>
        <Line text="Know who's waiting on you." inAt={s(0.1)} outAt={s(4.9)} size={64} />
      </div>
      <div
        style={{
          position: "absolute",
          left: tlx,
          top: tly,
          transformOrigin: "0 0",
          transform: `scale(${S})`,
          opacity: enter * (1 - exit),
          filter: exit > 0 ? `blur(${exit * 8}px)` : undefined,
        }}
      >
        <DashboardWindow t={frame - s(0.4)} page={page} pageMix={pageMix} select={select} inspector={inspector} queueT={frame - navClick} />
      </div>
      <Cursor
        frame={frame}
        keys={[
          [s(1.5), 1560, 980],
          [navClick - 10, nav[0], nav[1]],
          [rowClick - 30, nav[0], nav[1]],
          [rowClick - 6, row[0], row[1]],
        ]}
        clicks={[navClick, rowClick]}
        show={[s(1.5), s(5.05)]}
      />
      <div
        style={{
          position: "absolute",
          left: 0,
          right: 0,
          bottom: 0,
          height: 240,
          background: "linear-gradient(to bottom, rgba(12,16,28,0), rgba(12,16,28,0.78))",
          opacity: env(frame, s(5.6), out, 24, 20),
        }}
      />
      <div style={{ position: "absolute", left: 0, right: 0, bottom: 64 }}>
        <Line text="What they're asking. What to say next." inAt={s(5.7)} outAt={out} size={54} />
      </div>
    </AbsoluteFill>
  );
};
