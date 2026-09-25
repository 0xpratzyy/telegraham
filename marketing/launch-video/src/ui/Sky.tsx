import React from "react";
import { AbsoluteFill, Img, staticFile, useCurrentFrame } from "remotion";
import { track } from "../fx/track";
import { FLIGHTS, HEIGHT, SCENES, WIDTH, at, s } from "../timeline";
import { Flock } from "./Birds";

const IMG_W = 1850;
const IMG_H = 948;
const COVER = HEIGHT / IMG_H;

// One continuous camera move across the pidgy.chat illustration for the
// whole second half of the film: open high in the empty sky, tilt down to the
// tree, drift behind the product moments (blurred), and end pushing in on
// the kid napping under the tree.
const K = {
  f: [SCENES.hero.from, at("hero", 6.5), SCENES.queue.from, SCENES.values.from, at("values", 0.6), SCENES.channels.from, SCENES.end.from, SCENES.end.from + SCENES.end.dur],
  z: [2.0, 1.12, 1.2, 1.3, 1.24, 1.24, 1.1, 1.18],
  fx: [0.3, 0.33, 0.5, 0.42, 0.6, 0.55, 0.47, 0.52],
  fy: [0.12, 0.28, 0.42, 0.34, 0.3, 0.36, 0.6, 0.66],
  blur: [0, 0, 22, 22, 7, 14, 0, 0],
  dim: [0, 0, 0.42, 0.42, 0.22, 0.34, 0.02, 0.08],
};
const pts = (key: Exclude<keyof typeof K, "f">): [number, number][] => K.f.map((f, i) => [f, K[key][i]]);

export const Sky: React.FC = () => {
  const frame = useCurrentFrame();
  const z = track(frame, pts("z"));
  const fx = track(frame, pts("fx"));
  const fy = track(frame, pts("fy"));
  const blur = track(frame, pts("blur"));
  const dim = track(frame, pts("dim"));
  const w = IMG_W * COVER * z;
  const h = IMG_H * COVER * z;
  const left = Math.min(0, Math.max(WIDTH - w, WIDTH / 2 - fx * w));
  const top = Math.min(0, Math.max(HEIGHT - h, HEIGHT / 2 - fy * h));
  return (
    <AbsoluteFill style={{ overflow: "hidden", background: "#1B5BC0" }}>
      <Img
        src={staticFile("img/sky-field.jpg")}
        style={{
          position: "absolute",
          left: left - blur * 2,
          top: top - blur * 2,
          width: w + blur * 4,
          height: h + blur * 4,
          filter: blur > 0.3 ? `blur(${blur}px)` : undefined,
        }}
      />
      {FLIGHTS.map(([start, dur, n], i) => (
        <Flock key={i} start={start} dur={dur} count={n} seed={`fl${i}`} y={i === 0 ? 560 : 360} />
      ))}
      <AbsoluteFill style={{ background: `rgba(12,18,32,${dim})` }} />
    </AbsoluteFill>
  );
};

export const SKY_FROM = SCENES.hero.from - s(0.4);
