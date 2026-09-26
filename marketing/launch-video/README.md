# Pidgy launch video

A 60-second, 1920x1080 / 60 fps launch film for Pidgy, built entirely as code
with [Remotion](https://www.remotion.dev/). The soundtrack is synthesized from
scratch by `scripts/synth.ts`. No samples, no licensed music.

## Commands

```bash
npm install
npm run synth      # writes public/soundtrack.wav
npm run studio     # live preview + scrubbing in the browser
npm run render     # synth + full render -> out/pidgy-launch.mp4
npx remotion still PidgyLaunch out/frame.jpg --frame=600
```

In headless environments point Remotion at a local Chrome with
`REMOTION_BROWSER=/path/to/chrome`.

Props (edit in Studio or pass `--props`):

| Prop  | Default              | Shown on           |
| ----- | -------------------- | ------------------ |
| `cta` | `Download for macOS` | end-card button    |
| `url` | empty (hidden)       | line under the CTA |

## How it's put together

- `src/timeline.ts` is the single source of truth: 120 BPM (one beat = 30
  frames), scene boundaries, and every sound-design hit. Both the scenes and
  the synth import it, so cuts, slams, typing and whooshes line up with the
  music by construction. Retime a scene there and the audio follows.
- `src/scenes/` holds one file per beat of the story:
  noise, question, hero, tagline, lookup, topics, replies, recap,
  local-first, rapid-fire, end card.
- `src/fx/` holds reusable motion tools: easing curves, a `SplitText`
  reveal, a virtual `Camera` (shake / punch / directional motion blur), a
  `Whip` pan transition, grain, vignette, aurora backdrops and light
  streaks.
- `src/ui/` holds small re-creations of Pidgy UI built on the real design
  tokens from `Sources/DesignSystem/PidgyTokens.swift`, plus channel glyphs
  for Telegram, Slack, Gmail and WhatsApp.

Brand assets in `public/` are copied from `Sources/Resources`. The fonts
(Inter, Newsreader, JetBrains Mono) ship under the SIL Open Font License,
and their license files sit next to them.
