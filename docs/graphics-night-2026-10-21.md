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

## Rounds 02-04 - reviewed candidates, final validation pending

Round 02 corrects the impostor normal atlas transfer curve. The bake writes
normals through ALBEDO into an sRGB PNG; source_color decodes them before
NORMAL_MAP unpacks the direction. Opaque atlas pixels show 79.7% near-unit
directions after decoding, versus 4.5% without it. Matched clear/overcast
images show deeper distant foliage, with foreground materials unchanged.
No extra texture sample or geometry is added.

Four-view 1080p first pair: 41.96 to 40.83 FPS, mean 23.83 to 24.49 ms,
p95 27.98 to 31.30 ms. Repeat (after then before): before 43.39 / after 43.45
FPS, mean 23.04 to 23.01 ms, p95 28.73 to 29.83 ms. Mean cost is within noise;
the p95 increase needs another controlled check. Evidence: r02-* files.

Round 03 compares two clear-weather lighting grades. Candidate A (ambient
sky/fill .27/.30, contrast 1.08, saturation .92) was too subtle. Candidate B
(.18/.24, contrast 1.12, saturation .96) gives clearer road/vegetation
separation with readable rock and cloud detail. B is the visual selection;
other weather resets to the previous grade. Sun, fog and exposure remain
unchanged. r03-a-* / r03-b-* preserve both trials. One 1080p B run measured
40.51 FPS, 24.68 ms mean / 31.37 ms p95; no speedup is claimed. Next evaluate
local tree backlight, car headlights and paint instead of global contrast.

Round 04 attenuates dry dust by (1 - wetness)^2, retaining stones and water
spray. r03-wet.png to r04-wet.png removes the inappropriate beige cloud on
rain-soaked gravel; r04-mist.png retains reduced damp-road dust. This changes
emission, not allocated particle capacity. One 1080p wet pair measured
40.53 to 39.78 FPS, mean 24.67 to 25.14 ms, p95 32.58 to 34.46 ms;
repeat timing is needed and no speed gain is claimed.

## Round 05 - native 4K and measurement correctness

The old layout kept four 958x538 render targets even in a 4K window.
Each container now has a Node2D origin that maps physical pixels through the
root canvas scale; the HUD retains its logical layout. This avoids both
Control-local pixel snapping and float-offset cancellation on fractional
window sizes. At 3840x2160, four 1916x1076 native targets have 8-pixel gutters.
The real startup/resize integration test passed all 21 layouts (1/2/4 views,
1080p, 4K, fractional, odd, wide/tall and return to original dimensions).

Benchmark metadata records actual image readback dimensions outside the
measurement, viewport dimensions/render scales, car count and warmup.
Godot 4.5.2 ViewportTexture.get_size() misleadingly reapplies root stretching;
its reported size is recorded separately. Windowed 4K was clamped to
3840x2119, so use fullscreen and verify actual output 3840x2160.

Use --rivals 0: automated bot views otherwise add a fifth car, while normal
four-human defaults have none. The new target measures four cars, 240 warmup
and 1200 samples at --fixed-fps 120; physics stays at 240 Hz with four substeps.
Historical 60-Hz/five-car/1080p results are not directly comparable.
--benchmark-profile with --debug --gpu-profile is diagnostic only: script
profiling brackets the measurement; unprofiled runs decide performance.

## Round 06 - native 4K bottleneck isolation

Same four-car route, 240 warmup + 1200 measured frames at fixed 120 Hz,
3840x2160 fullscreen output, four 1916x1076 targets at native scale 1.0:

| Variant | FPS | Mean ms | p95 ms | p99 ms |
| --- | ---: | ---: | ---: | ---: |
| Round 05 baseline | 35.05 | 28.535 | 37.224 | 41.445 |
| Tyre uniform cache candidate | 34.81 | 28.725 | 38.886 | 41.828 |
| Diagnostic: trees removed | 53.33 | 18.753 | 24.829 | 27.616 |
| Diagnostic: grass removed | 36.98 | 27.039 | 35.915 | 38.865 |
| Diagnostic: cover removed | 36.22 | 27.610 | 35.630 | 39.985 |

Stripped scenes are diagnostics, not acceptable visual presets. Trees have
the largest effect (about 10 ms in this pair). Tyre caching does not yet show
a full-frame win; 2,869 imported/fallback-model equivalence checks passed.
Round 08's pre-shader run with tyre and HUD caches measured 35.064 FPS,
28.519 ms mean and 37.708 ms p95, close to the initial native baseline.

The CPU profile assigns 6.310 ms/frame to accumulated script self time:
1.584 ms suspension, .743 ms drivetrain, .663 ms stage lookup, .617 ms HUD
self (.950 ms including helpers). Arrow construction alone is .161 ms;
HUD geometry is now cached without changing per-frame readouts or draw calls.

Complete GPU intervals after warmup average approximately 12.428 ms opaque,
7.111 ms depth prepass, 2.011 ms TAA, 1.941 ms transparent, 1.726 ms shadows,
.504 ms glow and .408 ms SSAO (total 27.839 ms). These are reporting-interval
means, not exactly frame-weighted benchmark GPU means. CPU and GPU overlap;
do not subtract GPU time from wall time to infer CPU cost.

The reference gallery was searched again and the saved publisher forest image
was visually rechecked beside r05-native4k-four.png. Crowns still have flatter
yellow-green lighting; following cars' headlights appear to wash out front
cars. Test local tree lighting and daytime lamps separately after geometry.

## Round 07 - repaired needle tangent basis (staging validated)

All six baked tree meshes contained orthogonal unit tangents that did not
follow needle-card UVs. Repaired frames pass UV-alignment checks (>0.95).
The first reconstruction was rejected before saving because repacking also
quantized untouched normals. The final tool copies packed surfaces and
replaces only four tangent bytes per each of 52,566 needle vertices.
All other decoded arrays and packed fields, including nine non-needle
surfaces, remain identical. Generator tests cover rotated/mirrored UVs,
handedness, unchanged arrays and the degenerate-UV fallback.

Backups: r07-tangent-before / r07-tangent-after. Logs
r07-tangent-repair-packed.log and r07-tangent-assets.log pass. Source binary
promotion awaits review of r07-tangents-after-forest.png and
r07-tangents-after-four.png. The impostor bake uses geometric normals rather
than this tangent normal map, so this fix does not require rebaking its atlas.

## Round 08 - skip rasterizing fully faded trees

Per-block culling sends trees which fragment distance fading then discards
completely. Collapse those trees to zero-area triangles in the vertex stage,
keeping visible geometry, original dither and orthographic sun shadows.
A 2 m hidden margin keeps prior-frame vertices valid during visible transitions
for camera moves up to 2 m/renderframe. Bigger jumps exceed that guarantee.

First native 4K pair: 35.064 to 36.688 FPS, mean 28.519 to 27.257 ms,
p95 37.708 to 35.900 ms; draws and engine primitive counts are identical.
Both matched image pairs are byte-identical: r08-before/after-forest and
r08-before/after-moving. The moving capture includes 60 rendered frames of
history at about 107 km/h; existing foliage TAA smearing is unchanged.
This does not prove all temporal transitions or resets. Repeat timing is
running before acceptance.

## Round 09 - ordered spatial-query candidates

Precomputed ordered 3x3 neighborhood lists replace repeated road/river hash
lookups. Original traversal order, strict ties, hint preference, geometry
and RNG calls remain unchanged. Caches are immutable after index construction
and safe for terrain-builder worker reads. Typical extra memory is in the
low hundreds of KiB. tests/stage_queries.gd passed 41,514 exact-result checks
across six generated seeds, boundaries, ties, crossings, off-road hints,
water/grip thresholds and cache rebuilds. Actual 4K timing is pending.

Latest fully validated and pushed checkpoint remains f5926a7. The later
rounds above are candidates until full validation and export smoke pass.

Round 08 repeat (with repaired tangents fixed in both variants): 35.471 to
35.645 FPS, mean 28.192 to 28.055 ms, p95 37.131 to 37.025 ms, p99 40.330 to
42.468 ms. The larger first-pair gain did not repeat; no stable 4% speedup is
claimed. Retain the bounded rasterization reduction with pixel-identical
captures and no repeatable mean/p95 regression, while continuing to track tails.

Round 09 first native run with query caching: 37.015 FPS, mean 27.016 ms,
p95 34.903 ms, p99 38.200 ms, with exactly the same draw/primitive counters.
This is one run, not a confirmed isolated speedup. Raw comparison metadata is
saved in r09-benchmark-results.json.

The tangent captures were reviewed at native resolution. Near-needle lighting
changes locally without new seams, black facets, bright speckles or crown loss.
Quarter-screen differences are small; this is a material correctness repair,
not a major realism claim. Source binaries have now been promoted. Motion and
weather checks remain part of the next packaged-build review. Full source
validation is running; all five graphics regressions and handling have passed.

## Round 09 checkpoint - validated and exported

All required source checks passed: headless import, every project script,
five graphics regressions, handling bench, 45,000-tick seed-1 simulation and
GameNight lifecycle/controller checks. Simulation remains exactly
7c21ff6b71626d31 (two stages/two finishes, 143 shifts, four recoveries).
Handling metrics match the prior checkpoint. CI now runs the new regressions,
including repaired tree assets. Existing dummy-renderer/exit warnings remain.

Windows export and real-renderer smoke passed for four-player clear motion,
two-player wet motion and four-player mist, all at 3840x2160 output.
Actual captures r09-release-four/wet/mist.png were inspected: HUD/layout,
foliage silhouettes and weather are intact. Existing moving foliage TAA
smearing and flat distant lighting remain work for later rounds.

Verified build: C:\dev\sideways-graphics-20261021\build\Sideways-night-r09.exe
SHA256: 873a518623e3d9c94c2acc5dddb796ab9a37de2a60273943899e2b0462adcf13

Packaged native4K/four-car benchmark: 37.081 FPS,
26.968 ms mean, 35.088 ms p95,
38.838 ms p99, with four 1916x1076 targets at scale1.0.
The 120FPS/8.33ms target is still unmet. Retain rounds02-09 as this tested
checkpoint; individual small changes do not have proven independent speedups.
Next: isolate excessive daytime headlight fill, skip hidden tree wind math,
then test texture filtering and temporal reconstruction against the same route.

## Incoming main integration after round 09

The first push was rejected because main advanced to 844921b via c74c161.
Rebased the local graphics checkpoint fd04c1d onto that work (3a399c6),
resolving only the performance-probe comment conflict and preserving the
remote renderer-setup CPU metric. Incoming changes lower tyre substeps from
four to two, add per-wheel road hints and car-center water sampling, and
shorten tree distances to 25/70 m with an 8 m fade. Physics remains 240 Hz.
These are upstream changes, not isolated graphics wins; all subsequent A/B
comparisons must keep them fixed. The packaged round-09 build remains an
unchanged rollback/reference artifact. Full integrated validation is running.

Integrated checks passed: import, all project scripts, five graphics tests,
handling, 45,000-tick simulation and all eleven lifecycle checks. The new
simulation hash is 9ccd6036a18f0d99 (two stages/two finishes,151 shifts,
four recoveries), reflecting incoming simulation changes. The handling
bench remains close: 0-100 3.68 s, braking42.5 m,top213.6 km/h; 0-60 changes
2.00 to1.99 s and rest drift .19 to.22 cm. Do not claim unchanged physics
relative to the earlier four-substep build. Native GPU measurement follows.
