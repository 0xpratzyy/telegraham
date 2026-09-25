# Pidgy launch video

A 60-second, 1920x1080 / 60 fps launch film for Pidgy, built as code with
[Remotion](https://www.remotion.dev/). It follows the look, copy and music of
[pidgy.chat](https://pidgy.chat), and the product shots are the real app
screens rebuilt from the SwiftUI source. The creative plan is in
`brag-plan.md` and ready-to-post copy is in `share-copy.txt`.

## Commands

```bash
npm install
npm run synth      # writes public/sfx.wav (soft effects under the music)
npm run studio     # live preview + scrubbing in the browser
npm run render     # synth + full render -> out/pidgy-launch.mp4
npx remotion still PidgyLaunch out/frame.jpg --frame=1680
```

In headless environments point Remotion at a local Chrome with
`REMOTION_BROWSER=/path/to/chrome`.

Props (edit in Studio or pass `--props`):

| Prop  | Default          | Shown on        |
| ----- | ---------------- | --------------- |
| `cta` | `Request access` | end-card button |
| `url` | `pidgy.chat`     | next to the CTA |

## How it's put together

- `src/timeline.ts` is the single source of truth. The music bed runs at
  80 BPM, so each bar is 3 s, and every scene starts on a bar line. The
  timeline also holds typing and click timings and the sound-effect hit
  list. The scenes and `scripts/synth.ts` both import it.
- `public/golden-hour-haze.mp3` and `public/img/sky-field.jpg` are the
  pidgy.chat site's own music and illustration. The music is looped once on
  a bar line.
- `src/app/` holds the product screens, rebuilt at macOS point sizes from the
  app source and the Aug 15 audit screenshots:
  - The dashboard window (sidebar, Home with the `DashboardPigeonFlock`
    pigeons, Reply queue and the inspector).
  - The ⌘⇧T `LauncherView` panel.
  - A cursor.

  Everything uses the in-app tokens from `PidgyTokens.swift` and demo data
  only.
- `src/ui/Sky.tsx` is one continuous camera move over the illustration for
  the second half of the film. It is blurred behind the product moments and
  sharp for the hero and the end.
- `src/scenes/` holds one file per story beat.

After rendering, bake a settled frame in as the poster (frame 0) so every
platform shows it as the thumbnail:

```bash
npx remotion still PidgyLaunch out/poster.jpg --frame=3500
ffmpeg -i out/pidgy-launch.mp4 -i out/poster.jpg \
  -filter_complex "[0:v][1:v]overlay=enable='eq(n,0)'" -c:a copy out/pidgy-launch-poster.mp4
```

The fonts (Inter, Newsreader, JetBrains Mono) are under the SIL Open Font
License; the license files sit next to them in `public/fonts/`.
