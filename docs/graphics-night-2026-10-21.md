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

## Round 10 - daylight headlight fill

Integrated native baseline:41.430 FPS,24.137 ms mean,30.798 ms p95,33.539 ms
p99; four1916x1076 views,3840x2160 output,scale1,240 Hz/two substeps.
This combines upstream physics/LOD changes with the earlier graphics work.

Set only clear-weather headlight energy .30 to0; other weather unchanged.
Matched r10-before/zero-four,forest,moving captures show less pale rear-panel
fill on red/blue cars with road readability retained. Selected rear-panel
display luma falls14-17%; sampled sky/crowns are effectively unchanged.
The single-car forest full-image RGB MAE is.027/255. Yellow trunk highlight
is unchanged, so its material/reflection remains a separate issue.

First before/after:41.430/41.289 FPS,24.137/24.220 ms mean,30.798/31.832 ms
p95,33.539/35.668 ms p99. Reverse repeat before/after:40.552/40.827 FPS,
24.660/24.494 ms mean,31.833/31.803 ms p95,35.678/34.550 ms p99.
No repeatable performance change established. Retain for the local visual
improvement without repeatable mean/p95 regression. Benchmark metadata now
records tyre_substeps explicitly. Source full validation remains pending.
References: saved DiRT2 community captures (mod/filter status unknown) and
[official DiRT Rally2 gallery](https://store.steampowered.com/app/690790/).

## Round 11 - hidden-tree wind branch rejected

Candidate moved wind/hash computation into the visible branch of the existing
fully-hidden collapse. Static capture differs at only9/8,294,400 pixels, max
1/255; moving capture is byte-identical. No visual loss was established.
But neither native4K timing pair improved: baseline/candidate40.419/39.492
FPS (24.741/25.321 ms mean,31.581/32.588 ms p95), repeat40.681/39.948 FPS
(24.581/25.032 ms mean,31.913/32.279 ms p95). Background activity introduces
noise; there is no demonstrated benefit to justify the added branch. Reject;
staging shader restored exactly, source never changed for this experiment.

## Round 13 - query reset and reuse follow-up (validation pending)

Review of incoming surface hints found they survived teleport and could use
a stale road window after recovery. Clear all wheel hints in the existing
reset loop. Also reuse one tick-local center water query for suspension and
wading, replacing two identical calls. Preserve upstream two substeps and
center-water approximation; individual wheel bank entry remains approximate.
New focused regression passes31 checks/39 live physics ticks, including an
80 m reset onto a changing-width road, callback/hint updates, strict water
thresholds, missing callback and per-tick sampling. Added to CI. Full source
validation will run before retention/push.

## Round 14 - paired tree impostor bake

The old color and normal atlas alpha masks disagreed at 259,778 pixels
(intersection-over-union 0.56664). Their recorded billboard sizes also no
longer matched the current near meshes. Reworked the baker to capture each
color/normal pair with fixed camera/mesh state, disabled interpolation and
two real post-draw fences. It checks exact binary alpha agreement for every
view before saving. Two independent GPU bakes produced byte-identical PNGs.

Promoted the paired atlases and measured sizes 18.90518/14.06178/14.77670.
Albedo SHA256: 115f3ee76b1a78982127144b25bac31873a7cafa6a066c0f25634e6d3dab90b3.
Normal SHA256: 79eaab52df5defa39516defaef7c48c56ea44613f6a6ab418a47fbc8fa98e4ca.
The new asset regression checks all 24 cells and the sizes against mesh bounds.
The mismatch cause is not conclusively isolated to interpolation: stale
asset/model provenance is also plausible.

Reviewed matched clear four-player, single forest, moving, wet and mist shots.
Far crowns are more open and less bulbous, matching the sparse source meshes;
near crowns and foreground road remain stable. No new clipped rectangles,
missing whole crowns or white normal specks were visible. Wet darkness and
mist layering remain intact. Moving foliage trails persist; this still needs
a separate temporal-filtering experiment. This is a correctness repair, not
a major realism improvement.

Native4K before/after: 40.283/40.226 FPS, mean24.824/24.860 ms,
p95 31.666/32.227 ms, p99 34.706/34.947 ms. No speedup is claimed.
One temporary staging text-write error produced CRCRLF and a parser failure;
the failed log is retained, the bytes repaired, and the successful retry used
for these results. Full source checkpoint validation remains pending.

## Round 15 - mud overlay cost diagnostic

Temporarily removed the car mud overlays, then restored the exact source
bytes. Baseline/no-overlay/repeated-baseline: 39.932/42.012/40.390 FPS,
mean25.043/23.803/24.759 ms, p95 31.885/31.701/31.736 ms.
Average draw calls fell from3004.728 to2794.947. This suggests roughly
1 ms of potential work, but removal changes appearance even at dirt0 and is
not an accepted quality preset. Investigate preserving mud in fewer passes
or reducing its procedural fragment cost. No production change from this test.

Additional visual references: the five official
[DiRT Rally 2.0 Finland gallery images](https://store.steampowered.com/app/1118292/)
show darker crown interiors, brighter branch edges and more varied roadside
cover. Saved originals and hashes are in the local reference manifest.

## Round 19 - fully hidden impostor collapse rejected

Tested collapsing the far-tree quad after its original vertex calculations
when the existing conservative LOD helper says it is completely hidden.
Native4K A/B then B/A: baseline40.090/40.306 FPS, candidate39.663/39.839 FPS;
both candidate runs were roughly0.28 ms slower. No repeatable benefit was
demonstrated. The temporary shader is restored and this branch is not promoted.
This does not alter the previously retained near/mid tree rasterization guard.

## Round 20 - source checkpoint and Windows export

Full source validation passed: import, all36 project scripts, seven focused
regressions, handling,45,000-tick seed1 simulation and all11 GameNight lifecycle
checks. Atlas regression passes134 checks; car surface queries pass31 checks
over39 live physics ticks. Handling and simulation match integrated de5e947
exactly, including hash9ccd6036a18f0d99. Known headless/exit diagnostics remain
explicitly recorded; no new errors were accepted.

New export: C:\dev\sideways-graphics-20261021\build\Sideways-night-r20.exe
SHA256:78c4e067b4efbb7c457195b518143bf568aca7d92cb3c690f9df288c8a206050
Size:323,773,568 bytes. The previous r09 build remains untouched.
Packaged native4K/four-car benchmark:41.275 wall FPS,24.228 ms mean,
31.461 ms p95,33.017 ms p99, four1916x1076 viewports at scale1.0.
Clear4/wet2/mist4 packaged captures at3840x2160 were reviewed and are each
byte-identical to their matching R14 captures, with no new visual regressions.
Retain this source/export checkpoint. The first release runner stopped after a
successful import because ANSI formatting hid its completion marker; the
runner now normalizes ANSI before matching, and the retry passed all steps.

Benchmark interpretation: fixed120 keeps the same target-cadence route and
two240Hz physics ticks per rendered frame. At the measured wall rate, game
time therefore advances more slowly than real time. These measurements assess
the cost against the8.33ms target; they are not an assertion of free-running
play FPS. A separate normal-time diagnostic must be labeled and must not be
compared as the same route. Native4K/4player120FPS remains unmet.
