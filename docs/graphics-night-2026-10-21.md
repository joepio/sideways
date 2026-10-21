# Overnight graphics review — 21–22 October 2026

The user requested further autonomous iterations toward more realistic
graphics, retaining performance and four-player split screen. A thread
automation returns hourly through 07:00 Europe/Amsterdam on 22 October.
The opening baseline is `fa7dfbd`; prior measurements and official rally-game
references are in [the daytime report](graphics-performance.md).

## Evaluation loop

1. Read the latest accepted result and inspect current source/status.
2. Choose one concrete visual or rendering-cost hypothesis.
3. Capture and benchmark the current good version under matched conditions.
4. Make one bounded change and restart the renderer.
5. Inspect stationary and moving captures, clear/wet/mist, and 1/2/4 views.
   Look at the actual viewport size, road readability, material response,
   ground contact, foliage silhouettes, shimmer, ghosting and LOD transitions.
6. Compare wall-clock mean, p95 and p99 frame times plus draws/triangles.
   Repeat an A/B pair if timing noise could change the decision. Reject a
   repeatable >3% four-view mean or p95 regression unless a cheaper version
   of the visual improvement can be found. A prettier still frame alone is
   not evidence of better motion.
7. Keep only visually reviewed, tested improvements. Follow AGENTS.md checks,
   commit/push accepted work, and record rejected experiments as well.
8. Preserve a working Windows build. After 06:30 stop starting experiments;
   finish validation and produce the morning report by 07:00. No public/store
   release is part of this loop.

Use Godot 4.5.2 Forward+ at 1920×1080. For the comparable benchmark use
`--disable-vsync --fixed-fps 60 -- --benchmark 600 --views N --seed 4242
--at 300 --weather clear --km 2`. Discard 120 warmup frames. Run GPU tests
sequentially and do not change physics frequency to improve graphics scores.
Actual elapsed time, not fixed simulation delta, determines FPS.

The test copy is `C:\dev\sideways-graphics-20261021`. This night's raw logs
and captures go in `C:\dev\perf\sideways-night-20261021`, with a round prefix.
The earlier frozen baseline in `C:\dev\sideways-baseline-20261021` must stay
unchanged. Preserve other contributors' work and identify the current commit
before each round. If tools/permissions/GPU are unavailable, report the
blocker and do not claim an unmeasured improvement.

## Initial review queue

User steering: regularly fetch and inspect actual reference screenshots from
DiRT 2, with particular attention to colour correction. Before a colour/light
round and at least every two rounds, compare similar weather and camera
conditions against DiRT 2 (2009), DiRT Rally 2.0 and/or EA SPORTS WRC.
Record source URLs and distinguish official material from community captures
(whose mods/postprocessing may be unknown). Store references locally under
`references`; do not incorporate third-party screenshots into game assets.
Judge sun/shade separation, black point, warm highlights/cool shadows,
yellow-green balance, car/material contrast and atmospheric depth. Turn each
observation into a bounded experiment; protect highlight/shadow detail, car
paint colours, HUD and all weather conditions.

- Opaque road/terrain texture imports disable mipmap generation although the
  shaders request mip filtering and explicit coarse LOD samples. Test real
  mip levels first; treat cutout foliage separately to preserve alpha coverage.
- The baked impostor normal atlas appears sRGB encoded, but the shader samples
  it as linear. Test decoding this atlas without changing its colours or UVs.
- Atlas view dithering makes UV derivatives discontinuous; when enabling atlas
  mips, use gradients from the continuous cell UV to avoid incorrect mip choice.
- Moving foliage has ghosted silhouettes. Compare temporal AA alternatives
  only after texture sampling is correct, using sequences and split-screen cost.
- Wet gravel currently emits beige dry-weather dust. Make emission reflect
  wetness while preserving stones and water spray.
- Inspect baked tree tangents, car shadow bias and the zero-dirt mud overlay
  before adding more lighting effects or detail.

## Round 01 — opaque texture filtering

Hypothesis: real mip levels let distant road/terrain use filtered detail and
the road shader's intended average-colour samples, without losing close-up
surface detail. Tree alpha textures are excluded from this first experiment.

Changed mipmap generation on all 23 `assets/textures/*.jpg.import` resources.
Runtime inspection confirmed 10 or 11 actual mip levels. The new regression
checks imported gravel albedo/normal and cliff albedo image data, not just
the configuration flag. Captures show preserved close gravel with smoother
distant road/cliff detail. The pre-existing tree ghosting remains; this is
not a foliage or temporal-AA fix. Clear one/four-view, wet two-view and mist
four-view captures were inspected.

| Four-view run | Before FPS | After FPS | Before mean / p95 ms | After mean / p95 ms |
| --- | ---: | ---: | --- | --- |
| First pair | 35.48 | 34.89 | 28.19 / 38.42 | 28.66 / 39.73 |
| Repeat (after then before) | 42.16 | 46.73 | 23.72 / 28.43 | 21.40 / 25.20 |

The first pair was slightly slower; the repeat was faster. Background load
changed appreciably, so **no isolated overall-FPS gain is claimed**. There
was no repeatable >3% regression. Per-view GPU samples generally decreased,
but include queue spikes and are not a substitute for frame time. Draws and
triangles stayed exactly 3427.73 / 22.43M. Raw `r01-*-v4.log` files preserve
p50/p95/p99 and every periodic sample. This round's timing is four-view;
one/two views were visually checked.

Tradeoff: full mip chains add about one third to these textures' storage:
22,719,139 texels, approximately 65 MiB RGB8 or 86.67 MiB RGBA8 before any
backend compression. Actual GPU allocation was not measured. Texture memory
and compression remain relevant for the eventual minimum-spec test.

Decision: **accepted**. Source import, parse checks, graphics regression,
handling, the 45,000-tick simulation and all GameNight lifecycle checks passed.
Windows export and a four-view packaged-executable capture passed (exit 0);
`r01-release-four.png` was inspected. Existing headless/exit warnings remain.
The verified build is
`C:\dev\sideways-graphics-20261021\build\Sideways-night-r01.exe`.

Next: inspect the saved DiRT references, verify impostor-normal colour-space
decoding, then test a bounded lighting/colour adjustment against all weather
captures. Keep the mip change separate from tonal tuning in the record.

## Reference review for the next colour round

Actual images were downloaded and viewed, not inferred from search snippets.
`references/source-manifest.json` records original image URLs, source status
and capture authors; `references/color-review.txt` contains the detailed review.

- [DiRT Rally 2.0 publisher gallery](https://store.steampowered.com/app/690790/DiRT_Rally_20/):
  `dirt-rally-2-official-0.jpg` shows cool, dark canopy and warm sunlit trunks;
  the white car remains neutral. `dirt-rally-2-official-1.jpg` separates cool
  stone from beige gravel. These use promotional cameras, so they are colour
  references rather than matched gameplay or performance comparisons.
- [DiRT 2 capture by G.M.S.](https://steamcommunity.com/sharedfiles/filedetails/?id=10534802):
  `dirt2-community-0.jpg` has warm ground and deep, readable contact shadows.
- [DiRT 2 capture by Indie3k](https://steamcommunity.com/sharedfiles/filedetails/?id=39927685):
  `dirt2-community-1.jpg` contrasts warm road/dust with cooler sky/reflections.
  Both DiRT 2 images are community captures; settings, mods and postprocessing
  are unknown. Their appearance is not claimed to be stock rendering.

Compared with these references, Sideways concentrates too much of the car,
forest and road into similar beige/grey middle tones. Avoid adding a uniform
yellow filter. After checking the impostor-normal encoding, one bounded
**untested candidate** is clear-weather ambient sky share/fill 0.27/0.30
(currently 0.36/0.35), contrast 1.08 (1.02), saturation 0.92 (0.86), keeping
AgX, exposure, sun and fog unchanged. Reset defaults before applying each
weather profile so grading does not leak between stages. Reject crushed
forest/window detail, orange gravel or clipped clouds. These values are a
starting hypothesis, not an accepted visual change.
