import React from "react";
import { AbsoluteFill } from "remotion";
import { Line } from "../ui/Type";
import { BEAT, s } from "../timeline";

export const Values: React.FC = () => (
  <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
    <div style={{ position: "relative", width: 1700, height: 420 }}>
      <div style={{ position: "absolute", inset: 0, display: "flex", flexDirection: "column", justifyContent: "center" }}>
        <Line text="Pidgy notices." inAt={s(0.1)} outAt={s(2.55)} size={120} />
        <Line text="You decide." inAt={s(0.1) + BEAT} outAt={s(2.55)} size={120} italic />
      </div>
      <div style={{ position: "absolute", inset: 0, display: "flex", flexDirection: "column", justifyContent: "center" }}>
        <Line text="Everything stays on your Mac." inAt={s(2.9)} outAt={s(5.6)} size={104} />
        <Line
          text="No cloud. No telemetry. No “trust us.”"
          inAt={s(3.35)}
          outAt={s(5.6)}
          size={34}
          font="ui"
          color="rgba(255,255,255,0.8)"
          stagger={3}
          style={{ marginTop: 30 }}
        />
      </div>
    </div>
  </AbsoluteFill>
);
