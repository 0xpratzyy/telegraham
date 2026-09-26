import React from "react";
import { AbsoluteFill, Audio, Sequence, getStaticFiles, staticFile } from "remotion";
import { ensureFonts } from "./fonts";
import { Grain, Vignette } from "./fx/Overlays";
import { EndCard } from "./scenes/EndCard";
import { Hero } from "./scenes/Hero";
import { LocalFirst } from "./scenes/LocalFirst";
import { Lookup } from "./scenes/Lookup";
import { Noise } from "./scenes/Noise";
import { Question } from "./scenes/Question";
import { Rapid } from "./scenes/Rapid";
import { Recap } from "./scenes/Recap";
import { Replies } from "./scenes/Replies";
import { Tagline } from "./scenes/Tagline";
import { Topics } from "./scenes/Topics";
import { SCENES, type SceneId } from "./timeline";

ensureFonts();

export type LaunchProps = { cta: string; url: string };

const scene = (id: SceneId, node: React.ReactNode) => (
  <Sequence key={id} from={SCENES[id].from} durationInFrames={SCENES[id].dur} name={id}>
    {node}
  </Sequence>
);

export const PidgyLaunch: React.FC<LaunchProps> = ({ cta, url }) => {
  const hasSoundtrack = getStaticFiles().some((f) => f.name === "soundtrack.wav");
  return (
    <AbsoluteFill style={{ background: "#000" }}>
      {scene("noise", <Noise />)}
      {scene("question", <Question />)}
      {scene("hero", <Hero />)}
      {scene("tagline", <Tagline />)}
      {scene("lookup", <Lookup />)}
      {scene("topics", <Topics />)}
      {scene("replies", <Replies />)}
      {scene("recap", <Recap />)}
      {scene("local", <LocalFirst />)}
      {scene("rapid", <Rapid />)}
      {scene("end", <EndCard cta={cta} url={url} />)}
      <Vignette strength={0.5} />
      <Grain opacity={0.08} />
      {hasSoundtrack && <Audio src={staticFile("soundtrack.wav")} />}
    </AbsoluteFill>
  );
};
