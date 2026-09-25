import React from "react";
import { AbsoluteFill, Audio, Sequence, getStaticFiles, interpolate, staticFile, useCurrentFrame } from "remotion";
import { ensureFonts } from "./fonts";
import { Grain, Vignette } from "./fx/Overlays";
import { Channels } from "./scenes/Channels";
import { End } from "./scenes/End";
import { Hero } from "./scenes/Hero";
import { Launcher } from "./scenes/Launcher";
import { Opening } from "./scenes/Opening";
import { Queue } from "./scenes/Queue";
import { Values } from "./scenes/Values";
import { SKY_FROM, Sky } from "./ui/Sky";
import { DURATION, MUSIC_LOOP_AT, MUSIC_TRIM, SCENES, s } from "./timeline";

ensureFonts();

export type LaunchProps = { cta: string; url: string };

const span = (a: keyof typeof SCENES, b: keyof typeof SCENES = a) => ({
  from: SCENES[a].from,
  durationInFrames: SCENES[b].from + SCENES[b].dur - SCENES[a].from,
});

export const PidgyLaunch: React.FC<LaunchProps> = ({ cta, url }) => {
  const frame = useCurrentFrame();
  const hasSfx = getStaticFiles().some((f) => f.name === "sfx.wav");
  const skyIn = interpolate(frame, [SKY_FROM, SCENES.hero.from + s(0.3)], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  const fadeOut = (f: number) => interpolate(f, [DURATION - s(3), DURATION], [1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });

  return (
    <AbsoluteFill style={{ background: "black" }}>
      {frame >= SKY_FROM && (
        <AbsoluteFill style={{ opacity: skyIn }}>
          <Sky />
        </AbsoluteFill>
      )}
      <Sequence {...span("inbox", "buried")} name="opening">
        <Opening />
      </Sequence>
      <Sequence {...span("hero")} name="hero">
        <Hero />
      </Sequence>
      <Sequence {...span("queue")} name="queue">
        <Queue />
      </Sequence>
      <Sequence {...span("find", "prep")} name="launcher">
        <Launcher />
      </Sequence>
      <Sequence {...span("values")} name="values">
        <Values />
      </Sequence>
      <Sequence {...span("channels")} name="channels">
        <Channels />
      </Sequence>
      <Sequence {...span("end")} name="end">
        <End cta={cta} url={url} />
      </Sequence>
      <Vignette strength={0.28} />
      <Grain opacity={0.045} />

      <Sequence from={0} durationInFrames={MUSIC_LOOP_AT + s(0.8)} name="music-a">
        <Audio
          src={staticFile("golden-hour-haze.mp3")}
          trimBefore={MUSIC_TRIM}
          volume={(f) => interpolate(f, [MUSIC_LOOP_AT, MUSIC_LOOP_AT + s(0.7)], [0.9, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" })}
        />
      </Sequence>
      <Sequence from={MUSIC_LOOP_AT} durationInFrames={DURATION - MUSIC_LOOP_AT} name="music-b">
        <Audio src={staticFile("golden-hour-haze.mp3")} trimBefore={MUSIC_TRIM} volume={(f) => 0.9 * fadeOut(f + MUSIC_LOOP_AT)} />
      </Sequence>
      {hasSfx && <Audio src={staticFile("sfx.wav")} volume={0.8} />}
    </AbsoluteFill>
  );
};
