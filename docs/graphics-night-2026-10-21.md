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

## Round 20 - incoming CI update

Rebased the completed checkpoint onto incoming 9267267, which only updates
CI to Godot4.5.2 with verified download hashes and graphics-test timeouts.
Runtime files are unchanged by that integration. The resulting checkpoint
cc666b9 was pushed to main; the r20 executable and its validation still apply.

## Round 17 - isolated GroundCover normal change deferred

Changing only authored GroundCover normals from DOWN to UP removed some
local dark faces but left the dominant GrassField ribbons unchanged.
The single native before/after pair was21.688/24.028ms mean and31.430/30.919ms
p95, with identical draw/primitive counts. The mean regressed while the tail
improved, so this is not evidence of a causal performance difference.
Do not promote the isolated change. Exact Godot4.5.2 shader-source inspection
subsequently showed the renderer flips cull_disabled backface normals before
the user fragment function. The isolated change therefore swaps which faces
are dark. Round22 tests the complete authored-normal/backface correction.

## Round 21 - geometry and shadow cost isolation

Native4K/four-car fixed120 diagnostic,1200 measured frames after240 warmup:
baseline start23.624ms, baseline end23.945ms; trees hidden18.421ms,
GroundCover hidden23.422ms, GrassField hidden21.553ms, terrain hidden20.444ms,
shadows disabled19.329ms. Existing colliders and precomputed canopy remain.
These marginal differences are not additive, since hiding geometry changes
occlusion and other rendering work. They are cost probes, not quality presets.
Prioritize tree representation, shadow work and terrain over tiny shader
branches. No production quality setting or geometry was removed by this run.
## Round 22 - consistent grass lighting normals (validation pending)

Retain the joint repair: GroundCover supplies UP normals and both grass
fragment shaders undo Godot4.5.2's automatic backface flip. GrassField's
existing shrub correction is expanded to grass, not applied twice. Actual
renderer source places this side check before the user fragment function.
Clear single-player forest, clear moving four-player and wet moving two-player
matched captures were reviewed independently. Black blade backs disappear;
wet road/fog/car exposure remain consistent. The coarse blade silhouette and
pre-existing temporal tree smearing remain separate issues.

Native4K A/B then B/A baseline/candidate mean24.322/24.235ms and23.951/23.851ms;
p95 31.722/31.342ms and30.968/31.141ms; p99 32.426/32.203ms and32.006/32.287ms.
Draws and engine primitive counters are identical. These small mixed changes
establish no material performance cost or independent speedup. Retain for
visible lighting correctness. Temporary runs restored exact originals before
the reviewed joint files were copied to source and staging. Full required
source validation will run before the next pushed checkpoint.

## Authored pine crown trial - portable validation pending

An isolated candidate replaces only the twig surfaces of all six fir meshes
with fitted crowns derived from evolveduk's Pine Tree (CC BY4.0), retaining
all packed wood surfaces/materials/LODs exactly. The new near/mid crowns each
have1088 triangles. Variant c mid previously had576, so the change is not a
uniform per-mesh reduction. Texture provenance, modifications and attribution
are recorded in the experiment; runtime credits must accompany promotion.
The matching paired impostor atlases were baked twice byte-identically, with
exact alpha agreement across all24 cells and unchanged recorded camera sizes.

Reviewed actual clear1/clear4/wet2/mist4 captures and26 matched moving LOD
frames spanning40.32m. Crown structure is more coherent. No abrupt new crown
hole/disappearance was seen in the selected consecutive samples; pale backlit
foliage and existing horizontal temporal trails are still unresolved. The
candidate single-player forest capture was shown in chat.

Native4K/four-car fixed120 ABBA: baseline23.886310/23.881874ms mean;
candidate22.558149/22.265017ms. Mean across equal-length runs23.884092 to
22.411583ms (-6.165%); baseline endpoint drift0.004436ms. Average run p95
31.180 to29.8895ms (-4.139%), p99 32.1395 to30.747ms (-4.333%). These are
averages of run percentiles, not pooled percentiles. Engine primitive counter
16.657M to11.557M (-30.618%), draws3004.609 to3012.370 (+0.258%). The new
per-axis AABBs can affect culling despite identical maximum height/radius.
No claim of120FPS or exact GPU-triangle savings is made.

Evidence: C:\dev\perf\sideways-night-20261021\pine-crown-proof-20261022-001304.
Source/staging have not received this candidate. A portable guarded builder
and raw crown source data are under review and require engine validation
before promotion. The accepted R22 baseline is preserved separately for the
photographed-grass trial. Full source checks remain required for a checkpoint.


## Round 24 - retained simulation and rendering floor

Six native4K/four-car fixed120 runs in A/B/C then C/B/A order retain the
240Hz simulation, two tyre substeps, bots, cameras and HUD. A is reference,
B sets camera.cull_mask=0, C disables only each SubViewport's3D rendering.
Actual startup flags and final physical output/view counts were verified.
Reference mean24.129/23.583ms; empty3D6.916/6.977ms; no3D5.702/5.623ms.
No3D p95 is7.414/7.393ms and p99 is8.812/8.610ms. The optimistic floor fits
the8.33ms target in mean/p95 but already exceeds it in p99. It does not prove
that the complete game can reach120FPS with its desired graphics.

No3D is whole-app wall time with rendering suppressed, not a pure CPU timer.
Physics/scripts/HUD/composition and some shared work remain; visibility and
renderer work change and CPU/GPU costs overlap. These differences must not be
added as independent pass costs. All diagnostic edits were exactly restored.
Prioritize rendering work while preserving simulation behavior. Artifact:
C:\dev\perf\sideways-night-20261021\r24-cpu-floor-20261021T225324750419Z.


## Round 23 - depth prepass retained; SSAO visual gate pending

Native4K/four-car fixed120 A/B/C then C/B/A, each1200 measured frames after240
warmup. A retains SSAO and prepass; B removes SSAO but retains prepass; C removes
both. TAA stays enabled. Separate process startup avoids dynamic pipeline-cache
ambiguity. Project bytes and all imported asset caches restored exactly.

Reference means23.838908/24.127408ms, p95 31.080/31.589ms;
SSAO-off means21.030389/20.365983ms, p95 29.223/27.995ms;
no-prepass means28.163373/28.042838ms, p95 42.668/41.808ms.
Average run p99: reference32.368ms, SSAO-off31.089ms, no-prepass46.4525ms.
SSAO-off's first p99 was33.180ms, worse than its neighboring baseline31.977;
the second was28.998ms. Do not hide that tail variation behind the average.
No-prepass repeatedly regresses both mean and tail: reject it. SSAO-off is a
candidate only, pending matched four-player visual review and combined testing
with accepted crown geometry. One/two-player SSAO can remain enabled if a
four-player automatic policy passes review.

Engine source shows SSAO also requests a normal/roughness prepass attachment.
Thus A-to-B savings include that work as well as SSAO compute, not solely one
post effect. B-to-C removes the remaining depth-only prepass and is slower.
No quality change has been promoted from this trial. Artifact:
C:\dev\perf\sideways-night-20261021\r23-depth-prepass-20261021T230131981750Z.


## Round 30 - accepted crown/grass lighting checkpoint

The pine crown candidate was promoted to source and staging after portable
rebuild validation: 1,683 packed/decoded/material/metadata/LOD equality checks
passed, and two fresh paired atlas bakes matched each other and the reviewed
candidate byte for byte. Original wood surfaces remain unchanged. The guarded
builder and small raw crown inputs are included for reproducible future bakes.
Source/license notices are included both as export resources and loose files
beside the forthcoming Windows build. Promotion was hash guarded and backed up.

Round 27 halves foliage/impostor BACKLIGHT from (0.35,0.42,0.2) to
(0.175,0.21,0.1). Eight actual matched clear1/clear4/wet2/mist4 images were
reviewed; nearby crown interiors are darker while road, car and fog remain
consistent. Retained as a modest visual improvement. Native4K/four-player ABBA
means are approximately22.68/22.47ms reference and22.56/23.21ms candidate.
The average is about1.4% slower with mixed pairs; this is not evidence of an
independent performance gain or zero cost. Pale backlit foliage and temporal
trails remain visible and require further investigation.

Incoming commits84fc515 and57cc579 add render-scale choices with100% as the
default. A startup/reseat/resize bug was found: scaling was only applied by
setting and roster update callbacks. Applying it after physical viewport
layout fixes initial CLI choices, newly seated views and auto on resize.
Both ordinary and actual --render-scale75% integration runs now pass39 cases,
including native HUD sizing, FSR2 mode, TAA state, couch ordering and empty
roster followed by a new seat. Native100% remains the default.

Full source validation completed2026-10-21T23:25:41Z: import, all project
script checks, graphics, both view-resolution runs, tyre visuals, stage and
car-surface queries, tree tangents, paired atlas checks, handling,45000-tick
seed1/km2 simulation and GameNight lifecycle passed. Handling exactly matches
the accepted baseline; simulation hash remains9ccd6036a18f0d99 with2 finishes,
151 shifts and4 recoveries. Existing headless/shutdown diagnostics and the
standalone main.gd autoload limitation are recorded in the validation JSON;
there were no newly accepted diagnostics. Project settings restored exactly.

Evidence: C:\dev\perf\sideways-night-20261021\r30-validation-summary.json;
pine-crown-proof-20261022-001304; r27-foliage-half-backlight-20261021T230836765410Z
and r27-foliage-half-backlight-20261021T231442045091Z. A new packaged benchmark
and native4K captures are the next release gate. The120FPS target is not met.


R30 packaged release completed 2026-10-21T23:42:16.155867+00:00. New Windows executable:
C:\dev\sideways-graphics-20261021\build\Sideways-night-r30.exe
SHA256 35dd1c4e50da4d36f2bd07055686b2b302d10e59a0e11ab06355691a39d15a21; 324225656 bytes.
The export and all four packaged captures passed. Captures use continuous
fixed120 rendering from tick1: clear1 at900/tick240, clear4 at300/tick1600,
wet2 at300/tick1600 and mist4 at900/tick240. They are not compared with the old
R20 fixed60 partially rendered captures. R09/R20 builds remain preserved.
All three attribution/license texts are available loose beside the executable;
their exact bytes were also found inside the exported executable.

Fresh packaged native3840x2160/four1916x1076 views at scale1: mean22.2630817ms,
p9529.614ms, p9930.304ms,44.9174 wallFPS;3011.956 draws. Two240Hz simulation
ticks per controlled120Hz render remain fixed. This is a target-cadence cost,
not a free-running real-time gameplayFPS measurement. Previous R20 packaged
mean was24.228ms at a different time; the earlier paired pine experiment is
the stronger causal evidence. The8.33ms target is still unmet.

R23's new eight-image SSAO-only gate on the combined R30 staging passed visual
review at four-player size plus native crops. Removing SSAO slightly lightens
wheel/underbody contact and grass roots; existing shadows, crown volume and
wet/mist readability remain. Proposed policy is SSAO enabled for1/2 views and
disabled for3/4, pending a fresh combined R30 ABBA. No policy has been applied.
Artifact: r23-ssao-visual-20261021T233332465420Z. Project/runtime/cache restored
exactly. Its versioned R30 helper explicitly requests render-scale100% and pins
the validated startup-layout code; the original helper remains preserved.

A new incoming commit4edb0da independently fixes initial/resize render scaling.
When integrating it, consolidate the equivalent callbacks into the already
validated _arrange_views call; avoid applying scaling twice for each layout.
Keep the incoming behavior and the39-case regression coverage.


## Round 31 - automatic SSAO budget and explicit reconstruction metadata

On accepted R30, native4K/four-view ABBA reference means22.4274875/20.3037117ms
versus SSAO-off18.9061900/19.0190225ms. Both pairs improve:15.70% and6.33% in
mean,10.64% and3.28% in p95. Reference endpoint drift is9.47%, so no precise
single percentage is claimed. p99 improves in both pairs (31.421->29.158 and
30.885->28.161ms). Draws and engine primitive counters match exactly.
Eight matched visual images passed review with slightly lighter wheel/grass
contact shading; near crowns, wet roads and mist remain readable.

Retain automatic SSAO for one/two views and disable it for three/four. Real
reseating restores the proper state, weather changes preserve it, and the
existing --strip ssao diagnostic takes precedence. Shadow settings are unchanged.
PerfProbe now records actual TAA state in benchmark JSON and mode/scale/TAA in
periodic per-view observations, supporting explicit native versus FSR2 trials.

Full source validation passed: import, all project parses, graphics,48 viewport
cases in both normal and CLI75% runs, tyres, stage/car queries, tangents, atlas,
handling,45000-tick simulation and lifecycle. R30's earlier count was39 per run;
its note is corrected from40. Handling and simulation remain unchanged. Known
engine diagnostics remain separately recorded. Project settings restored exactly.
The four changed runtime/test files were hash-guarded and copied to staging.
Artifacts: r23-ssao-r30-bench-20261021T234640374680Z and
r31-validation-summary.json. Latest packaged build remains R30 until the next
combined visual checkpoint; no claim that the old executable has this policy.


## Round 12 resumed - production CLI reconstruction comparison

The replacement CLI-only runner uses the validated R31 render-scale lifecycle
and actual mode/scale/TAA metadata. Shared staging is unchanged. Four clear
moving images and two wet4 images were captured with continuous fixed120
rendering from tick1 to1600. All output is3840x2160; four-view output viewports
are1916x1076. Native100% uses mode0/TAA; reconstructed67% uses mode2/FSR2 with
TAA disabled and actual scale0.6700000167. The native100% default is retained.

Matched native/67/67/native ABBA, current R31 including SSAO off for4 views:

| Run | Internal choice | Mean ms | p95 ms | p99 ms |
| --- | --- | ---: | ---: | ---: |
| A1 | native100% |19.0391567|27.065|28.149|
| B1 | FSR2 67% |15.4940325|18.303|24.079|
| B2 | FSR2 67% |15.6517742|18.541|23.546|
| A2 | native100% |19.4273808|27.489|28.579|

Mean across runs19.2332688 versus15.5729033ms, a19.03% reduction; both paired
orders improve. Native baseline end-to-end drift is2.04%. Mean of per-run p95
is27.277 versus18.422ms; this is not a percentile of pooled samples. Draws rise
from3011.9558 to3410.4858, so draw count alone does not explain total GPU cost.
Controlled target-cadence cost is not normal free-running gameplay FPS. Neither
choice reaches the8.33ms/120fps four-player target.

Two reviewers found much less horizontal foliage smearing in the reconstructed
endpoints and sharper wall joints, but more fine grain on vegetation/road/paint
and a stepped yellow roof/windscreen edge. Wet-road patches, fog depth, car
identity and HUD remain intact. Still-image gate permits continued evaluation;
a short consecutive-frame sequence is required before recommending the choice
on visual grounds. This is an existing optional setting, not a new accepted
runtime change. Native4K and reconstructed4K remain separately labelled.

Evidence under night: r12-cli-20261022T000429140531Z (four clear images/crops),
r12-cli-20261022T000830571391Z (ABBA and analysis.json), and
r12-cli-20261022T001151903032Z (wet4 pair). The legacy R12 layout-patch runner
must not be used after the centralized render-scale implementation.

## Photo-grass early prototypes - held for combined validation

R25 original24cm six-triangle photographed clumps were too low and dark.
R25b36cm improves coverage but nominal card area is2.25x, so a triangle-count
reduction does not establish a speedup. R25c changes only ALBEDO root factor
.45 to.8, retaining AO.45, height, density, wind and wetness. Both reviewers
prefer its cleaner root/soil blend. Repeated rounded clumps and coarse old
GroundCover blades remain; screenshots are endpoints, not temporal proof.

These early variants use the deliberately frozen older R22 tree baseline.
A separate combined GrassField/static-GroundCover trial is prepared from R31
with its current crowns/SSAO policy and proper independent static shader.
No photographed-grass candidate is promoted yet. Original photo maps are
Poly Haven Grass Medium01, CC0, credited to Rico Cilliers and Rob Tuytel;
provenance and packaged notice accompany the candidate. See R25/R25b/R25c
isolated folders and grass-combined-candidate-20261022 for exact artifacts.


## Round 33 - match distant foliage normals to the authored crown

The baker now samples the actual foliage normal texture using the same signed
RG/positive-Z tangent-frame convention as near foliage. The far-tree shader
unpacks all three signed atlas axes, reverses the selected atlas-cell rotation
and uses the actual instance basis captured in the vertex stage. Normal atlas
and both shaders must be kept together. Wood mapping and nonuniform-Y foliage
remain approximations; this does not claim exact near/far shading identity.

Two independent 24-cell bakes were byte-identical. Albedo remains exactly the
accepted original and paired alpha is binary and exact. New normal PNG SHA256:
aa41b88e7f2e65fb0fe0566e11e7c0f0a2cd4c9ada4172e89984e0141cb05dc7.
Actual shader probe, four early images and eight clear/wet/mist moving images
passed review. Two reviewers retained the more legible dark crown interiors.
A further 26 matched approach frames included seven consecutive drawn frames;
no new flash, black flip or silhouette hole was observed there. The recorded
camera path matches exactly. Tree identities/origins and selected atlas cells
were not logged, so this is not proof of a particular LOD or atlas-cell crossing.
Existing pale near branches and TAA history streaks remain.

Isolated R30/SSAO-on ABBA means22.7064/22.6491ms baseline versus22.6910/22.1267ms
candidate: averages22.6777 versus22.4089ms (-1.19%). This small result is treated
as neutral, not a robust speedup. Per-run p95 averages30.086 versus29.669ms;
draws3012.37 and engine primitive counters match. Do not compare those costs
directly with R31's automatic SSAO policy.

At2026-10-22T00:54Z the three codefiles and exact normal atlas were promoted to
source and staging after guards verified the original code, six tree meshes,
Forest setup, near shader, both authored leaf textures and import settings.
Original bytes and EOLs are preserved in r33-promotion-20261022T005403Z.
Full repository validation and a fresh Windows export are the remaining gates.
Evidence: normal-contract-isolated/runs/{early-20261021T235056860132Z,
extended-20261022T001404368663Z,bench-20261022T002212415906Z};
pine-crown-proof-20261022-001304/normal-contract-R30-sequence-20261022T002649308917Z.

Combined photographed GrassField/GroundCover early4 on R31 completed separately
in grass-combined-isolated/runs/early-20261022T003703715721Z. Fine blades improve
wall/soil contact and remove broad polygon tufts. Dark rounded repetition remains,
so no production promotion yet. The next isolated variant raises the same cards
from.36 to.50m while holding their exact width; card area rises38.9% and cost is
unproven. Texture analysis correctly normalizes the16-bit alpha before cutoff.

R12 motion captured64 consecutive frames for each of native100/FSR67 in1p/4p:
256 actual3840x2160 images, ticks1504-1630 with exact camera/progress matches
and actual mode/scale/TAA metadata. Source/staging were unchanged during capture.
These readback/PNG-encoding runs are visual evidence only, not timing samples.
Artifacts: r12-motion-20261022T004021376692Z. Detailed temporal review pending.

R33 full validation passed on the frozen240Hz/two-substep basis, including
48 normal/CLI viewport cases, handling,45k simulation and lifecycle. Handling
and simulation match R31. Incoming85b5e72 was then discovered on origin/main:
it independently changes world physics to120Hz/four tyre substeps. Integrate
and revalidate that changed basis before the next export. Graphics A/B evidence
above retains its original240/2 basis; no physics benefit is attributed to it.


R33 checkpoint completion (2026-10-22T01:17Z): source8028273 integrates the
incoming120Hz/four-substep physics change. The full new-basis validation passed
all checks after an evidence-based diagnostic reclassification. The original
failed classification remains in r33-120-validation-summary.json. An isolated
unmodified85b5e72 archive reproduced exactly the same handling metrics, complete
simulation state/hash and30 null-material dummy-renderer diagnostics at the
same location (plus the existing single two-resource exit diagnostic). Only
that measured count ceiling changed; no other diagnostic was suppressed.
Reviewed result: r33-120-validation-reviewed-summary.json; comparison evidence:
r33-incoming-baseline-20261022T010848391541Z. The simulation now covers375s,
four stages and six finishes, hashceeb673e45f28349. This is a new physics basis,
not evidence of a graphics speedup or unchanged physics relative to240/2.

The new Windows executable is C:\dev\sideways-graphics-20261021\build\Sideways-night-r33.exe,
324764760 bytes, SHA256a1e6902416999bbbfbd88152520efe66594f8cfc1681182059f93d59202fea82.
Export, native4K/four-player benchmark, actual clear1/clear4/wet2/mist4 screenshots
and resource-system readback of all three embedded license texts passed. Existing
loose licenses are unchanged and text-identical; source CRLF differs from their
old LF bytes after rebase, explicitly recorded. Older executables are preserved.
Evidence prefix: r33-120-release; packaged-license JSON records exact new hashes.
Actual output3840x2160; four1916x1076 views; mode0/scale1/TAAtrue;120Hz/four substeps.
One fixed120,1200-frame run after240 warmup frames: mean19.3551708333ms,
p9527.251ms, p9928.206ms,51.6658 wallFPS,3022.3525 mean engine draws. This is
controlled route cost, not free-running gameplayFPS;8.33ms target is still unmet.
All four packaged images were inspected. Existing large camera lag, pale near
foliage and TAA streaking remain visible and are the next separate hypotheses.

R12's completed temporal review retains native100 as the quality reference.
Across64 consecutive roof-edge samples FSR67 reduces crown history trails but
adds grain and unstable coarse steps on the yellow roof. No default promotion
or visual-equivalence claim. Review and native-pixel comparison videos are in
r12-motion-20261022T004021376692Z/independent-visual-review.txt and its adjacent
review-* artifacts. The four R16 roughness early shots now run on120/4; no new
paint/camera/terrain/grass changes are part of this R33 executable.


## R16 / R18 early gates on the new120/4 basis

R16 completed four native4K static captures at300ticks (2.5s):1p forest900 and
4p grid300, roughness.38 versus.24, all other material values unchanged. Both
reviewers reject.24 for insufficient realism benefit. Red/blue gain only small
bumper-highlight changes; yellow Toyama's existing broad gold/white band becomes
narrower/harder without supplying environment reflection structure. No new
catastrophic chrome patch, but no reason to extend this candidate. Keep.38.
No timing claim; exact original staging bytes restored. Evidence:
r16-paint-native-120-4-early-20261022T011735511436Z, including independent review
and native-pixel car crops. No production paint change.

R18 completed four moving native4K endpoints at800ticks (6.667s) in1p/4p.
Horizontal velocity-relative damping keeps the camera near its intended boom
instead of accumulating speed-dependent lag. Own cars are visible in4p again;
1p retains the full car and road ahead. Both reviewers see no new body/terrain
penetration in these endpoints. Existing neighbour overlap and TAA streaks
remain. This is a framing gate only: braking, real contact, reverse/lateral
motion, crests, reset and FAR/CHASE events at multiple render cadences must be
checked before promotion. No world/vehicle physics or Y damping was changed.
Evidence: r18-camera-native-120-4-early-20261022T011947311102Z. No production
camera change yet; exact staging bytes restored.

R26 first capture attempt completed the1p pair then crashed during unchanged
4p baseline startup: Vulkan lost-device breadcrumbs while door_sticker._bake
read back a viewport, before a completed capture/benchmark. Failed logs and
exact restoration are retained in r26-native-120-4-shots-20261022T012319348200Z.
One fresh bounded full-sequence retry started; this crash is not a timing sample
or evidence that the candidate shader caused it.


R26 retry completed all8 screenshots without a new startup failure. Independent
review of four matched overview pairs and six native crops finds no visible seam,
new mip blur or contrast change. Clear1/wet2/mist4 max RGB differences2/1/1;
clear4 has only16 pixels above2 out of8.29M. This is endpoint evidence only.
Fresh ABBA means: baseline19.220245/19.1562567ms, candidate19.1975167/19.0536825ms.
Run averages19.1882508 versus19.1255996ms (-0.3265%). p95 run averages27.1985
versus27.279ms (+0.296%); pair1 p95 worsens0.95%, pair2 improves0.36%.
Draws match3022.3525 and native120/4 metadata match. Decision: do not promote;
no meaningful visual gain and no reliable useful performance gain. Keep simpler
existing shader. Evidence: r26-native-120-4-shots-20261022T012606390547Z and
r26-native-120-4-bench-20261022T013714075934Z/decision.json. Original shader restored.

R34 native AA early4 completed: FSR2scale1 versus nativeTAA, both full internal
resolution. Strong reduction of long crown trails and more branch/wall/rock
detail in actual1p/4p images. Fine stippling on paint, yellow roof, grass and road
is still visible at1:1; no coarse67%-style roof plateau observed in these stills.
Do not promote from endpoints. Separate cost, motion and weather gates remain.
Evidence: r34-native-aa-120-4-20261022T013148270035Z, including independent review
and native crops. No runtime/source file change in this diagnostic.

The first bounded R18 brake event run is deliberately NOT_COVERED, not a camera
pass/fail: r18-camera-events-120-4/runs/brake-pair-20261022T014050626671Z.
Baseline captured1320 render/physics frames (three-second countdown plus8s).
Full braking began at tick614,20.0104m/s; actual speed fell below10m/s at1235,
after contact and sideways rotation. The required final+1s event image at1355
falls beyond the8s capture. Candidate was not started. A separate9s driver
preserves all original evidence and requires1440 consecutive ticks plus exact
target-vehicle/event parity before a paired result. Capture costs are not timing.

Read-only Godot4.5.2 source audit found no demonstrated custom foliage/wind
motion-vector error in native TAA. Its closest-depth clipping helper does select
minimum raw reverse-Z depth and has a shifted velocity fetch. Open upstream
PR123844 independently identifies both issues; it is not merged. This affects
history clipping in our engine, not the main current-pixel reprojection lookup.
Our specific trails' causal contribution remains unmeasured. Merged PR112196
uses a different tighter clipping strategy in4.6; no engine replacement or
patch was made. Evidence: tree-motion-vector-readonly-20261022, including
reverse-z-upstream-followup.txt. https://github.com/godotengine/godot/pull/123844

R34 native-AA ABBA completed on120/4. Native TAA means19.1850325/19.2568817ms;
native FSR2 means21.3806192/20.4524400ms. Run averages19.2209571 versus20.9165296ms
(+8.8215%); both pairs regress. p95 run averages27.114 versus28.7035ms; baseline
drift0.3745%. FSR draws3421.2508 versus3022.3525; same output/view dimensions and
physics. This is too costly for default promotion toward8.33ms. A bounded motion
proof can still identify quality tradeoffs; existing75%FSR2 is the next cheaper
alternative, explicitly reconstructed rather than native4K. No runtime writes.
Evidence: r34-native-aa-120-4-20261022T014911710905Z/decision.json.

Grass height-only early4 completed in grass-height50-isolated/runs/
early-20261022T015924879053Z. Both variants retain the identical historical
R31/240Hz/two-substep basis; these are not R33 release comparisons. All four
images and four native crop pairs were reviewed. Keep.50m as the preferred
prototype shape: more upright fine stems and irregular tops, especially along
the rock foot and wall base; ground gaps remain visible. No new solid hedge,
black card rectangle or broad stretched ribbon. Dark round clumps and repeated
distant dots remain. Height is not a colour fix. Only height changed; width
stays.685333m, projected card area can rise38.9%. No cost or temporal claim and
no promotion. Current120/4 combined-grass qualification is being prepared.

R18 nine-second pair completed: brake-pair-9s-20261022T015301775289Z, both1440
consecutive traces and13PNG files; exact target-car nine-field and brake-event
parity passes. Target AABB minimum distance improves.526 to2.186m, pre-brake
trailing distance9.755 to5.161m. Twelve matched brake-window images show better
target framing without target-body penetration. This is not a world-clearance
pass: radius.12m queries report static-world contacts at1407-1409 baseline and
1375-1377 candidate. The stored window ends at1355, so no actual crossing pixels
were captured. Stage.height differences are only a terrain proxy, not measured
penetration depth. A separate sparse pair will capture those exact moments and
verify replay trace identity before deciding whether camera avoidance is needed.

R34 bounded motion completed with32 consecutive native4K frames per method,
ticks752-783: all four car/camera trajectories match exactly. All32 roof/crown
crop pairs were reviewed. Native FSR2 retains more branches, crown openings and
trunks and reduces broad horizontal TAA smear; fine changing stipple remains
on crowns and the yellow roof. No coarse one-frame crown disappearance or large
roof-block jump seen in this short31/120-second span. No shimmer-free or real-time
playback claim. Higher cost and this tradeoff retain TAA as default. Evidence:
r34-native-aa-motion-120-4/runs/20261022T020209036593Z.

Pine SPECULAR-zero early4 completed on current120/4 with exact shader restore:
pine-specular-zero-120-4-early-20261022T020752025607Z. Both reviewers see greener,
darker nearby foliage and more internal branch separation; four-player distant
olive/pale crowns and horizontal temporal trails remain. No new silhouette gap
or obvious hard LOD band in these endpoints. Zero is a partial diagnostic, not
accepted final material; near/mid wood is unchanged but the far atlas includes
wood. A smaller reduction (.125 near/.10 far) is a possible next bounded test.

Local static reflection proof completed all four current120/4 captures:
local-probe-20261022T021103583328Z. Exact identical in-memory car tagging, cars,
lights, decals and views in both variants; candidate only adds one stationary
UPDATE_ONCE probe. Red/green gain colour depth, with little identifiable forest
structure from these rear views. Blue stays pastel; yellow gets a narrow hard
white trunk highlight. Glass becomes darker and loses some interior contrast;
lamps/trim also change because the receiver mask is geometry-wide. No visible
reflected car, HUD/decal displacement or cubemap seam seen in these captures.
Keep as a limited startgrid proof; no route, startup-cost or production claim.

### 04:24–04:33 — current grass gate, Stage XZ correctness and camera crossing

The current R33/120 Hz/four-substep grass candidate passed import, parse and the .50 m mesh/material contract, followed by four actual native 4K early images (one player in the forest and four players moving). Independent review found finer, irregular blades and improved rock/soil contact compared with the broad procedural triangles. Darker rounded repeated patches remain. Evidence: `grass50-current-120-4-isolated/runs/early-20261022T022049168387Z`, including the independent review and native crops. This is only the clear-weather early image gate; ABBA cost evaluation is running separately before further art work or promotion.

R32 Stage XZ cache correctness passed on the actual current physics basis: `r32-stage-xz-120-4-checks-20261022T022456361178Z`. Stage/car query contracts, handling and all 45,000 simulation ticks match the accepted current/incoming oracle exactly, including `ceeb673e45f28349`. Temporary staging changes restored exactly. The staging handling test was first synchronized byte-for-byte from the source HZ120 version; its prior HZ240 file is preserved in `r32-bench-basis-sync-20261022T0224`. Timing is a separate subsequent gate; no performance gain or production acceptance is claimed yet.

The R18 sparse crossing rerun captured 16 actual images and reproduced each variant's entire 1,440-tick target-car/camera/query trace against its own nine-second reference, then checked paired target-car physics parity. These are target-car guarantees, not all-car guarantees. Candidate terrain penetration becomes visibly evident between sampled ticks 1380 and 1406; baseline penetration between 1410 and 1440. The sphere hit itself is not the visible defect. Evidence: `r18-camera-events-120-4/runs/crossing-pair-9s-20261022T021610644180Z`. A small CHASE/FAR static-world avoidance correction is being prepared before accepting the improved follow camera; no Stage.height proxy is used as collision ground truth.

The latest publisher reference pass is `references/reference-pass-20261022T0218.txt`: DiRT Rally 2.0 Finland image 2. Useful visual differences are irregular narrow grass blades, broken soil edges, granular road texture and dark conifer interiors. Promotional capture settings are unknown; this supplies art direction, not matched performance evidence.
### 04:37 — grass50 cost gate passes after qualified repeat

First current-basis ABBA: `grass50-current-120-4-isolated/runs/bench-20261022T023021423913Z`. Baseline A1=25.81538 ms and A2=19.52583 ms drifted substantially, while candidate B1=18.08872 and B2=18.30177 ms. Preserve the raw result, but do not quote its aggregate -19.74% as stable gain. The separate decision explicitly requires a repeat.

Repeated unchanged ABBA: `bench-20261022T023402273959Z` in the same runs folder. A1=19.3203975, B1=18.09064, B2=18.0100042, A2=18.9778375 ms. Average baseline19.1491175 to candidate18.0503221 ms (-5.7381%); paired improvements -1.2297575 and -0.9678333 ms. Baseline end drift -1.77%. Mean/p95/p99 improve in both paired comparisons. Average run p95 moves27.0335 to26.2495 ms and p99 28.0855 to27.6935 ms; these are averages of per-run percentiles, not pooled percentiles. Exact native4K/four-view/120Hz/four-substep readbacks and post-run file integrity pass.

Decision: continue weather and motion qualification, not yet production acceptance. This measures the combined photo carpet/static-grass change and cannot isolate height, shader or geometry contributions. Primitive counter changes are not verified hardware-triangle savings. The overall 8.33 ms target is still unmet.
### 04:42 — Stage XZ timing does not justify promotion

Eight runs completed and all staging bytes restored: `r32-stage-xz-120-4-bench-20261022T023732477801Z`. Rendering-disabled ABBA averages4.144455 to4.230528 ms (+2.0768%), with both paired means/p95/p99 worse. Native ABBA averages19.263144 to18.965698 ms (-1.5441%); p95 run-average27.102 to26.9355 ms, but p99 28.0545 to28.429 ms and tail pairs are mixed. Native baseline end drift is about-0.162%. The mean native improvement is real within this run, but the intended route-computation benefit is not corroborated by the rendering-disabled diagnostic. Decision: retain the original implementation for now rather than promote this small mixed result. This is not proof that every rendering setup would regress. The no3d figures are whole-application diagnostics, not pure CPU time or playable FPS.
### 04:44–05:24 — grasmotion, schaduwkosten, begrensde cameracorrectie

- De huidige .50m fotograsvariant (gain1) is opnieuw in acht echte native4K
  weerbeelden beoordeeld: clear1 moving, wet2, wet4 en mist4. Fijne halmen en
  contact met rots-/muurvoet verbeteren; compacte donkere pollen blijven een
  aandachtspunt. Geen nieuwe duidelijke losse roots of zwarte kaarten in deze
  eindbeelden. Bewijs: `grass50-current-120-4-isolated/runs/extended-20261022T024419832175Z`.
- De afzonderlijke motionvergelijking bevat32opeenvolgendeframes per variant,
  ticks750–781,0.25833s first-to-last,7.288m afgelegd. Doelauto/camera/viewport/
  physics en afgeleide shaderTIME zijn exact gelijk. Alle64beelden onafhankelijk
  beoordeeld: geen duidelijke nieuwe grasspop, kaartdraai of lange ghosttrail;
  fijne randen blijven TAA-zacht. Dit is een korte clear1pcontrole, geen bewijs
  van volledig flikkervrij gras in alle omstandigheden.
  `grass50-motion-120-4/runs/20261022T030626649714Z` en
  `grass50-motion-independent-review-20261022`.
- Een gain1.25-variant wijzigt uitsluitend de twee lineaire ALBEDO-factoren.
  Vier native4K clear1/clear4-beelden geven een lichte voorkeur: beter leesbare
  sprieten, geen zichtbare uitgebeten tips, maar de ronde kernen blijven.
  Dit betekent geen25%toename in schermhelderheid. Gerichte wetvergelijking
  volgt; de gain1 timing/motion/weather-resultaten worden niet als gain1.25
  metingen voorgesteld. `grass50-albedo125-candidate-120-4/runs/20261022T031416836299Z`.
- Richtingsschaduw4096→2048 houdt filters/precisie, twee splits,80m afstand,
  blend/bias en alle overige renderinstellingen gelijk. Vier vroege4pbeelden
  (stilstaand en bewegend) door root en peer goedgekeurd: geen opvallende nieuwe
  blokken, grove trapranden of contactverlies in de bekeken gebieden.
  ABBA:19.153942,17.471868,17.555293,19.456602ms. Gemiddeld
  19.305272→17.513581ms(-9.2808%); gemiddeldep95 27.261→24.7425,
  p99 28.8505→26.1875. Beide paren winnen; baseline-einddrift+1.58%.
  `directional-shadow-2048-candidate/bench-runs/20261022T030134603885Z`.
  Alleen kostengatePASS; echte spelerswissels, herstel naar4096 bij1/2spelers,
  regen/mist en bewegende schaduwen moeten nog worden gecontroleerd. Deze
  winst mag niet bij de graspercents worden opgeteld zonder gecombineerde run.
- De R18wereldcorrectie laat de vrije camera spring/heading en doelfysica exact
  gelijk. Een .25m spherecast tegen uitsluitend statische wereldgeometrie
  verkort het weergegeven camera-armstuk wanneer nodig. In de16late beelden
  verdwijnen de terreinvoids uit alle acht avoidance-samples; unresolved0,
  anchorlift0,70ingrepen op ticks1371–1440,minimumcar-AABBafstand.373744m.
  Bij de laatste beelden staat de camera zeer dichtbij de auto. Nog geen
  promotie: echt herstel/FAR/CHASE en lage rendercadans volgen. Spherequeries
  zijn geen zelfstandig pixelbewijs en shaderrelief is niet volledig afgedekt.
  `r18-world-avoidance-120-4/runs/20261022T025625111091Z`.
- MID64 blijft onbeslist. De eerste visibilityprobe berekent correct2160
  camerasamples,57204actievegroepen en minimaal4.055992m marge, maar faalt
  strikt op exit-resources. De teardown-retry verwijdert de vier texture-RID
  leaks, houdt sampling/report exact, en laat nog twee resources bij exit over.
  Geen beelden of timing geaccepteerd; oude fouten/evidence blijven intact.
  `forest-mid64-120-4-cleanup-isolated/runs/early-20261022T031720385818Z`.
- Verse referentie05:16: officiële DiRT Rally2.0 Scotland/ColinMcRae-FLATOUT
  Steambeelden, https://store.steampowered.com/app/1211480/DiRT_Rally_20_Colin_McRae_FLAT_OUT_Pack/ .
  Diepe krooninterieurs met belichte fijne naalden ondersteunen een gerichte
  specularproef; geen reden om de hele kleurcorrectie warmer te zetten.
  Promotionele opnames met onbekende instellingen, geen prestatievergelijking.
- Nog geen runtimepromotie sindsR33. Nieuwe grasproductiebundel met echte
  geometry/UV/mip/material/auto1–4-regressietest en CI-stap is gereviewd.
  R35validatie/release worden voorbereid met exact120/4oracle en een bytekaart
  vóór/na validatie, zodat geëxporteerde runtime aantoonbaar dezelfde is.

### 05:25–05:55 — gras geselecteerd, camerarecovery en reconstructie

De grasvariant met lineaire albedo-factor 1.25 is geselecteerd voor de volgende
gecombineerde build. De gerichte natte vergelijking bij vier spelers
(`grass50-albedo125-wet4-120-4/runs/20261022T033147738136Z`) is door root en een
onafhankelijke reviewer goedgekeurd: fijne halmen blijven leesbaar, donkere
wortels en openingen naar de grond blijven behouden, zonder nieuwe heldere
band of emissief ogende toppen. De eerdere kosten- en motionmetingen betreffen
factor 1; de gecombineerde build moet zijn eigen meting krijgen.

De productie-regressietest is werkelijk uitgevoerd. Godots dummy-headless
RenderingServer levert identity-transforms voor MultiMesh-readback, ook wanneer
de ingestelde transform daarvan afwijkt. Daarom controleert de headless test
geometry, UVs, wortels, mipmaps, materialen, aantallen en grid-eigenschappen;
alle echte placementasserties blijven behouden in een aparte Vulkan-run met
`--gpu` en een non-identity sentinel. Beide runs slagen. De oorspronkelijke
mislukte test en diagnose blijven bewaard. Definitieve bundel:
`grass50-production-bundle-120-4-v2`, manifest SHA256
`7e62f2cee89c801111450fc127eea441a6a148a4371bd7483afded655509b5c2`.
Selectie en bewijs staan in `r35-grass-acceptance-review.json`.

De cameravariant is aanvullend gecontroleerd met reset, FAR en CHASE bij zowel
120 als 40 gerenderde frames per seconde, steeds met dezelfde 120 Hz fysica en
vier bandensubsteps. Doelposes, events en vrije cameraveer zijn per vergelijking
exact gelijk; geen onopgeloste world-collision. Bij 120 FPS zijn er 75 ingrepen
(ticks 1371–1445); bij 40 FPS 25 ingrepen. Minimumafstand van de getoonde eye tot
de auto-AABB is respectievelijk 0.2202 en 0.2863 m. Alle 32 eindbeelden zijn
beoordeeld: normale framing keert na reset terug, FAR/CHASE werkt. Korte rode
TAA-rest bij reset verdwijnt in volgende samples. Dit bewijst geen natuurlijke
terugkeer uit een obstakel zonder reset en geen continue bewegingskwaliteit.
Bewijs: `r18-world-avoidance-120-4/recovery/runs/20261022T032345078085Z` en
`20261022T033501193803Z`. Kosten versus de echte R33-camera zijn nog te meten.

De halve specular-factor voor dennen heeft in heldere beelden een lichte
voorkeur: minder zilveren naalden en dieper groen, met behoud van belichte
naalden. De verre bleke lagen en TAA-sporen blijven. Het verre hout deelt het
impostormateriaal en verandert dus mee. Bewijs:
`pine-specular-half-120-4-early-20261022T031925083047Z`. Natte controle volgt;
nog geen promotie of kostenclaim.

Het dynamische schaduwbeleid heeft 163 lifecycle-asserties gehaald, maar twee
kwalificatieruns faalden strikt op resources bij afsluiten. Geen foutmeldingen
zijn uitgezonderd. De fixture wachtte mogelijk te kort op de asynchrone
DoorSticker/Canopy-bakes; een begrensde wacht op het verdwijnen van de werkelijke
bake-SubViewports wordt nu met verbose resource-identiteiten gecontroleerd.
De runtimewijziging blijft uitsluitend atlasgrootte 2048 bij 3/4 spelers en
herstel van geconfigureerde grootte/precisie bij 0/1/2 spelers. Regen/mist,
herstelbeelden en motion zijn nog vereist voor promotie.

FSR 75 is opnieuw op de huidige fysicabasis gestart: vier echte vergelijkingen
bij 1 en 4 spelers, tick 800, in
`r12-cli-120-4-20261022T034532512934Z`. De uitvoer blijft 3840×2160; interne
resolutie is 75% per dimensie met FSR2. Native gebruikt scale 1/mode 0/TAA;
75% gebruikt mode 2 zonder aparte TAA. In de getoonde beelden zijn boomtakken
scherper en de lange native-TAA-vegen kleiner. Fijne spikkeling, autoranden en
beweging vereisen nadere beoordeling. Nog geen kostenmeting of defaultswitch.

R35-validatie vereist de exacte bestaande 120/4 handling- en simresultaten,
import, alle scripts, lifecycle en de nieuwe headless plus echte GPU-grastest.
Een runtime-bytekaart bindt de volledige validatie aan de latere export. Alleen
nieuwe UID-bestanden van aantoonbaar ongewijzigde owners mogen tijdens import
ontstaan. De release zal naar een nieuwe executable gaan; eerdere builds en
licenties blijven bewaard. Op dit tijdstip is nog geen runtimewijziging sinds
R33 in de bron geïnstalleerd.

### 05:57–06:02 — eerste R35-bronpromoties

Gras met factor 1.25 is exact uit de beoordeelde v2-bundel geïnstalleerd; alle
13 bronbaselines en bewijzen zijn gecontroleerd. Backup en transcript:
`r35-grass-promotion-20261022T035738521276Z`. Staging en de R33-executable zijn
ongewijzigd. De volledige gecombineerde validatie en export moeten nog volgen.

De complete cameracorrectie is als kwaliteitsverbetering geaccepteerd en exact
geïnstalleerd. Kostenproef `r18-world-avoidance-120-4/cost-runs/20261022T035409156888Z`:
A1 19.75869, B1 19.58132, B2 19.13932, A2 19.14969 ms. Gemiddeld
19.45419 naar 19.36032 ms (-0.48%), kleiner dan de -3.08% baseline-einddrift.
Gepaarde means -0.17737 en -0.01037 ms; p95 -0.544 en -0.398 ms; p99 -1.477
en +0.137 ms. Geen aangetoonde betekenisvolle totale regressie, geen
snelheidswinstclaim. Andere camera-framing verandert ook zichtbaarheid en
renderwerk: dit is geen geïsoleerde querymeting. De betere kadrering en
verholpen onderzochte terreinvoids dragen de keuze. Backup en acceptatie:
`r35-camera-promotion-20261022T040012378388Z`.

De schaduwfixture sluit nu werkelijk schoon af: 163 beleidsasserties, alle
asynchrone bakes voltooid en uitsluitend de twee geregistreerde Stage-objecten
expliciet opgeruimd, exit 0 zonder resource-uitzondering. Dit is geen reparatie
van productieownership: `Stage` is een Node3D die `main._new_stage()` wel maakt
maar niet parent of vrijgeeft; de twee noise-resources blijven daardoor leven.
Dit blijft als afzonderlijke bevinding staan. Een typed-array runtimefout in de
capture-observer wordt gericht hersteld voordat de acht beelden worden
herhaald. De bestaande schaduwpolicy verandert daarbij niet.
