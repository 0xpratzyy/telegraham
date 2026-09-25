import { continueRender, delayRender, staticFile } from "remotion";

const faces: [string, string, string][] = [
  ["Inter", "fonts/Inter.ttf", "100 900"],
  ["Newsreader", "fonts/Newsreader.ttf", "200 800"],
  ["JetBrains Mono", "fonts/JetBrainsMono.ttf", "100 800"],
];

let loaded = false;

export const ensureFonts = () => {
  if (loaded || typeof document === "undefined") return;
  loaded = true;
  const handle = delayRender("Loading Pidgy fonts");
  Promise.all(
    faces.map(([family, file, weight]) => {
      const face = new FontFace(family, `url(${staticFile(file)}) format('truetype')`, { weight });
      document.fonts.add(face);
      return face.load();
    })
  )
    .then(() => continueRender(handle))
    .catch((err) => {
      console.error(err);
      continueRender(handle);
    });
};
