import React from "react";
import { AbsoluteFill, useCurrentFrame } from "remotion";
import { Camera } from "../fx/Camera";
import { Flash } from "../fx/Overlays";
import { clamp, ease, kick, prog } from "../fx/easing";
import { C, CHANNEL, FONT } from "../theme";
import { Glyph } from "../ui/Glyph";
import {
  CHANNEL_ORDER,
  IMPLODE_START,
  QUESTION_CHANNEL_FLASH,
  QUESTION_TEXT,
  SCENES,
  questionCharFrame,
} from "../timeline";
import { NoiseField } from "./NoiseField";

const L = (abs: number) => abs - SCENES.question.from;

export const Question: React.FC = () => {
  const frame = useCurrentFrame();
  const abs = frame + SCENES.question.from;
  const dur = SCENES.question.dur;
  const implode = clamp((frame - L(IMPLODE_START)) / (dur - L(IMPLODE_START) - 4));
  const imp = ease.inExpo(implode);
  const typed = QUESTION_TEXT.split("").filter((_, i) => abs >= questionCharFrame(i)).length;
  const lastKey = typed > 0 ? questionCharFrame(typed - 1) : -99;
  const typing = typed < QUESTION_TEXT.length;
  const caretOn = typing || Math.floor(frame / 15) % 2 === 0;
  const freezeFade = prog(frame, 0, 18);
  const split = imp * 40 + kick(abs, lastKey, 4, 0) * 3;
  const dot = clamp((frame - (dur - 10)) / 10);

  const textLayer = (color: string, dx: number) => (
    <div
      style={{
        position: "absolute",
        inset: 0,
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        transform: `translateX(${dx}px)`,
        mixBlendMode: "screen",
        color,
      }}
    >
      <div style={{ fontFamily: FONT.mono, fontSize: 72, fontWeight: 500, letterSpacing: -1, whiteSpace: "pre" }}>
        <span style={{ color: color === "white" ? C.accent : color }}>› </span>
        {QUESTION_TEXT.slice(0, typed)}
        <span
          style={{
            display: "inline-block",
            width: 34,
            height: 70,
            marginLeft: 4,
            verticalAlign: "-12px",
            background: color === "white" ? C.accentHover : color,
            opacity: caretOn ? 1 : 0,
          }}
        />
      </div>
    </div>
  );

  return (
    <AbsoluteFill style={{ background: "black" }}>
      <AbsoluteFill
        style={{
          filter: `blur(${4 + freezeFade * 10}px) saturate(${1 - freezeFade * 0.8}) brightness(${1 - freezeFade * 0.72})`,
          transform: `scale(${1.14 + frame * 0.0004})`,
        }}
      >
        <NoiseField t={SCENES.noise.dur} layer="back" implode={implode} />
        <NoiseField t={SCENES.noise.dur} layer="front" implode={implode} />
      </AbsoluteFill>
      <Camera id="q" zoom={1 + imp * 0.5 - (1 - freezeFade) * 0.05} rot={imp * -4}>
        <AbsoluteFill style={{ transform: `scale(${1 - imp * 0.9})`, opacity: 1 - dot }}>
          <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
            <div
              style={{
                width: 1720,
                height: 170,
                borderRadius: 28,
                background: "rgba(18,19,24,0.82)",
                border: `1px solid ${C.border3}`,
                boxShadow: `0 40px 120px rgba(0,0,0,0.7), 0 0 90px rgba(79,127,220,${0.18 + kick(abs, lastKey, 5, 0) * 0.1})`,
                transform: `scale(${0.94 + freezeFade * 0.06})`,
                opacity: freezeFade,
              }}
            />
          </AbsoluteFill>
          {textLayer("#ff2a55", -split)}
          {textLayer("#2af0ff", split)}
          {textLayer("white", 0)}
          <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
            <div
              style={{
                display: "flex",
                gap: 40,
                marginTop: 260,
                fontFamily: FONT.ui,
                fontSize: 36,
                fontWeight: 600,
                color: C.fg1,
              }}
            >
              {CHANNEL_ORDER.map((id, i) => {
                const at = L(QUESTION_CHANNEL_FLASH[i]);
                const p = ease.outBack(clamp((frame - at) / 12));
                if (frame < at) return <div key={id} style={{ width: 250 }} />;
                return (
                  <div
                    key={id}
                    style={{
                      width: 250,
                      display: "flex",
                      alignItems: "center",
                      gap: 12,
                      justifyContent: "center",
                      transform: `scale(${p}) translateY(${(1 - p) * 30}px)`,
                    }}
                  >
                    <Glyph id={id} size={58} tile />
                    <span>{CHANNEL[id].name}?</span>
                  </div>
                );
              })}
            </div>
          </AbsoluteFill>
        </AbsoluteFill>
        <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
          <div
            style={{
              width: 18,
              height: 18,
              borderRadius: 9,
              background: "white",
              boxShadow: "0 0 40px 12px rgba(145,172,232,0.9)",
              transform: `scale(${dot * 1.5})`,
              opacity: dot,
            }}
          />
        </AbsoluteFill>
      </Camera>
      <Flash amount={(1 - freezeFade) * 0.5} />
    </AbsoluteFill>
  );
};
