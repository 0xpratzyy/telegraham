import React from "react";
import { AbsoluteFill, spring, useCurrentFrame, useVideoConfig } from "remotion";
import { AppIcon } from "../fx/Overlays";
import { env } from "../fx/track";
import { FONT } from "../theme";
import { Line } from "../ui/Type";
import { s } from "../timeline";

export const Hero: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const out = s(8.2);
  const icon = spring({ frame: frame - s(1.5), fps, config: { damping: 16, stiffness: 90 } });
  const iconEnv = env(frame, s(1.5), out, 20, 24);
  const name = env(frame, s(2.3), out, 30, 24);

  return (
    <AbsoluteFill style={{ alignItems: "center", justifyContent: "flex-start", paddingTop: 170 }}>
      <div style={{ opacity: iconEnv, transform: `translateY(${(1 - icon) * 30}px) scale(${0.9 + icon * 0.1})` }}>
        <AppIcon size={168} />
      </div>
      <div
        style={{
          marginTop: 30,
          fontFamily: FONT.ui,
          fontWeight: 700,
          fontSize: 132,
          letterSpacing: -4,
          color: "white",
          lineHeight: 1,
          opacity: name,
          filter: `blur(${(1 - name) * 10}px)`,
          transform: `translateY(${(1 - name) * 18}px)`,
          textShadow: "0 4px 40px rgba(10,30,80,0.35)",
        }}
      >
        Pidgy
      </div>
      <Line text="Every message finds its way home." inAt={s(3.0)} outAt={out} size={70} style={{ marginTop: 28 }} />
      <Line
        text="Find any message. Know who's waiting. Reply with context."
        inAt={s(4.6)}
        outAt={out}
        size={30}
        font="ui"
        color="rgba(255,255,255,0.78)"
        stagger={2}
        style={{ marginTop: 22 }}
      />
      <div style={{ opacity: env(frame, s(5.4), out), marginTop: 18, fontFamily: FONT.mono, fontSize: 20, letterSpacing: 3, color: "rgba(255,255,255,0.6)" }}>
        LOCAL-FIRST · MAC-NATIVE
      </div>
    </AbsoluteFill>
  );
};
