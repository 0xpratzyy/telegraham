import React from "react";
import { Composition } from "remotion";
import { PidgyLaunch, type LaunchProps } from "./PidgyLaunch";
import { DURATION, FPS, HEIGHT, WIDTH } from "./timeline";

const defaultProps: LaunchProps = {
  cta: "Request access",
  url: "pidgy.chat",
};

export const RemotionRoot: React.FC = () => (
  <Composition
    id="PidgyLaunch"
    component={PidgyLaunch}
    durationInFrames={DURATION}
    fps={FPS}
    width={WIDTH}
    height={HEIGHT}
    defaultProps={defaultProps}
  />
);
