# Graphics performance â€” 21â€“23 October 2026

The current target is **120 FPS with four players at native 3840Ã—2160**:
8.33 ms per frame. **This target has not been reached.** Later experiments,
visual decisions and validation are recorded in the
[night iteration log](graphics-night-2026-10-21.md) and
[daytime playtest log](graphics-playtest-2026-10-22.md).

## 23 October: distant shadows and menu text

The integration includes GameNight room-log update `8caf46d` and phone-action
SDK update `02ad07d`. Directional
contact-hardening shadows are disabled (`light_angular_distance = 0`), while
ordinary filtered shadow maps remain enabled. On Godot 4.5.2, the old PCSS
setting made the car shadow disappear as the same scene moved away from the
world origin. This matches [Godot issue/fix #120774](https://github.com/godotengine/godot/pull/120774).
The menu's corrupted encoded arrows are replaced with ASCII `< value >`.

The real-renderer regression uses the actual Asti at 0 and 2,000 m with identical
relative camera/light poses, under the production one-view and four-view shadow
policies. Its neutral receiver does not cast a shadow itself. On/off differences
outside the car bounds must retain nonzero ground-shadow energy and a similar
spatial distribution. With the fix, far/near energy ratios are 1.0017 and 0.9672;
normalized spatial differences are 0.0107 and 0.0493 (limit 0.25). Restoring only
angular distance 0.6 fails both policies: energy ratios fall to 0.0082 and 0.0053,
with spatial differences above 1.98. All 16 candidate/control images are retained.
The four-view policy remains visibly softer/grainier in this diagnostic. This
proves translation stability, not complete shadow quality, motion quality,
actual four-viewport performance, or a fix for wheel-arch sky reflections.

Fresh validation passed: import, all 55 project-script parses, weather/view
policy checks, exact historical handling, the 45,000-tick simulation (unchanged
`f31f454d8d6d2cb9`), and GameNight lifecycle. Physics remains 120 Hz/four substeps.
After the late SDK update, import/script parsing and lifecycle were rerun.
The recorded baseline-only headless/autoload diagnostics remain; the shadow
regression exits cleanly. Early scene captures reproduce the same texture/RID
and resource-exit diagnostics in R41 and the candidate; they are visual evidence,
not a clean-exit qualification. No new performance or release-export claim.

Evidence: `C:\dev\perf\sideways-main-merge-20261023`, including
`validation-result.json`, `merge-checks-summary.json`, and
`shadow-candidate/shadow-translation.json` with its negative control.
Run the regression with the real renderer:

```sh
godot --path . --fixed-fps 120 --resolution 512x512 --disable-vsync --script res://tests/shadow_translation.gd
```

Unfinished wheel-arch occlusion, foliage mip/view blending, and junction/water
experiments are excluded. Their available local artifacts are preserved outside
the runtime in the merge evidence directory and the original R42/R43 directories.

## Current source and R41 validation

The current source defaults to **auto render scale and spatial AA**. Auto starts
at approximately 75% for a total 3840Ã—2160 output, regardless of the number of
split views; 1080p starts at native scale. It selects one shared scale between
50% and 100%, preserving native output/HUD dimensions. Spatial uses FXAA at
native resolution and FSR1+FXAA below it; temporal uses native TAA or FSR2.
Lower scales reconstruct 4K output and must not be reported as native 4K.
Neither AA choice has established stable vegetation across all motion/weather:
TAA leaves broad crown smears, spatial reveals grain/jaggies, and FSR2 can leave
grass grids and paint stipple.

The controller samples the sum of valid root and active-view GPU timestamps,
with half-second windows, hysteresis and slower quality recovery. It does not
reduce scale in response to wall FPS alone. The timestamps are asynchronous
latest values without a frame identifier, and exclude some work outside the
viewports; the 7.5 ms budget is a conservative control signal, not a complete
GPU-frame measurement or a 120 FPS guarantee. Manual modes stay fixed.
Loading, menu, pause, headless tests, screenshots and ordinary deterministic
benchmarks suspend adaptation; an adaptive benchmark requires an explicit flag.
The R40 integration diagnostic recorded a real 75â†’85% decision and 107.69
instrumented FPS, with a preserved cleanup failure. It is not a release benchmark.

The R41 merge through `10b1f75` introduces per-view near/mid/shadow tree sets,
private camera layers and delayed spare-buffer swaps. Three tree variants use
nine MultiMesh nodes per view; this is not a claim of nine total renderer draws.
Far impostors remain grouped separately. Shared wind time and disabled fern
shadows are also integrated. Their combined cost and motion quality are pending.
Reused tree slots must disable physics interpolation: otherwise Godot delays
buffer readback and interpolates unrelated tree identities. After that fix,
414 actual GPU buffer/lifecycle checks passed, including the two-draw swap.

R40 was **not released**: its actual GPU shadow custom-data checks failed after
the original block instance-uniform design exhausted the renderer's pool.
R41 replaces those payloads with per-tree origin-based shadow fading. Its full
frozen suite passes: import/script checks, functional regressions, exact original
handling, lifecycle, and fresh actual GPU grass/forest/TreeSets checks. Both
45,000-tick simulations exactly reproduce the explicit R40 route observation
`f31f454d8d6d2cb9`; R40 itself remains an unqualified graphics build. The complete
input map is unchanged. Existing narrowly bounded headless/autoload diagnostics
remain recorded; the GPU checks have no new error/resource exceptions.
Evidence: `C:\dev\perf\sideways-playtest-r41-20261022\r41-final-evidence.json`.
The actual export passes embedded-license, texture/mipmap/shader/material and
GameNight lifecycle checks without a source project path. Build:
`C:\dev\sideways-playtest-r41-20261022\build\Sideways-r41.exe` (328079056 bytes),
SHA256 `5b4a1b7397eab3772d4f77ed1a025e55a1c70250600e2926f9b3b4fa874f4b3f`.
Package evidence: `release-runs/20261022T125555378941Z/summary.json` in the R41
artifact directory. The source/staging parity review accounts for all 348
validated inputs: 346 exact pairs and two historical standalone tools covered
by the explicit `tools/*` export exclusion, without runtime/test exceptions.
Wet-road facets and the existing nonzero mud coverage possible at `dirt=0`
remain unresolved; the daytime log records the rejected experiments.

## R41 actual packaged native/auto measurements

Four cars/views, total 3840Ã—2160 output, spatial AA, seed4242 at300 m, clear,
vegetation auto, rivals0; 1200 measured frames after240 warmup, fixed120,
120 Hz/four substeps. Native uses scale1/FXAA; auto uses FSR1+FXAA below1.

| Order | Weather / scale choice | Wall FPS | Mean ms | p95 ms | p99 ms |
| --- | --- | ---: | ---: | ---: | ---: |
| A1 | Clear native100 | 110.53 | 9.04762 | 11.263 | 13.842 |
| B1 | Clear auto | 98.41 | 10.16157 | 13.298 | 15.086 |
| B2 | Clear auto | 76.54 | 13.06548 | 16.227 | 17.609 |
| A2 | Clear native100 | 115.47 | 8.65993 | 10.595 | 11.864 |
| Separate | Wet auto | 118.16 | 8.46334 | 10.187 | 11.117 |

Native mean averages8.85378 ms (about113 FPS); auto averages11.61352 ms,
31.17% more time in these pairs. Both auto runs are slower, but their large
variation prevents a general cost or cause attribution. Each auto run makes
one75â†’85% step at4.61â€“4.85 ms sampled viewport GPU cost, without oscillation.
This demonstrates decisions, not a speedup. CPU limitation and upscaler overhead
remain hypotheses. Wet is an unpaired smoke run. Every run explicitly retains
the exact historical one-resource exit diagnostic; it is not a clean-exit claim.
Evidence: `release-performance-20261022T130437321559Z/results.json` in OUT41.

The earlier native4 preflight averaged120.15 FPS but had10.13 ms p95; it is
neither part of this ABBA nor proof of sustained120 FPS. A native1 capture at900 m
was substantially slower despite a similar scene-node count. Route-specific CPU
profiles are pending; do not blame total collider count or extrapolate one
route's rate. Fixed120 controls simulation advance, not free-running gameplay
cost. Broad motion/weather acceptance and a stable120 FPS result remain open.

## Historical qualified R35 build â€” 22 October, 120 Hz / four substeps

The historical R35 executable preserves 120 physics ticks per second and four
tyre-solver substeps. It includes the incoming streaming/terrain-LOD/grass-ring
changes (`6ba9eb7`, `e1235b5`), photographed grass, compatible ring placement,
camera following/world avoidance, lower pine specular and the split-screen
shadow-atlas policy. Full import, script parsing, handling, 45,000-tick
simulation, lifecycle, headless graphics and actual Vulkan grass-placement
checks passed. Handling and simulation exactly match the accepted 120/4 oracle.
All 288 runtime files remained byte-identical throughout the final validation.
The exported executable also passed texture/mipmap/shader/material and all
four embedded-license readbacks.

| Packaged build | Mean ms | p95 ms | p99 ms | Route wall-clock FPS |
| --- | ---: | ---: | ---: | ---: |
| R33, 120 Hz / four substeps | 19.35517 | 27.251 | 28.206 | 51.6658 |
| R35, 120 Hz / four substeps | 15.91653 | 19.459 | 24.390 | 62.8278 |

Both use the same native 3840Ã—2160 four-player route protocol: 1200 measured
frames after 240 warmup frames, fixed render cadence 120, seed 4242, at 300 m,
clear weather, vegetation auto, no rivals, explicit 100% render scale. Each
split viewport is 1916Ã—1076 at scale 1 with TAA. This is a controlled route
comparison, not typical gameplay FPS or an adjacent balanced A/B test. R35
uses about 17.8% less mean frame time than the earlier R33 reference, with
multiple combined changes; do not attribute the total to any one change.
The 8.33 ms target remains unmet. Historical 240 Hz results below are separate.

Build: `C:\dev\sideways-graphics-20261021\build\Sideways-night-r35.exe`
(328080480 bytes), SHA256
`911706d92325b7f2ff9d073b88c884f13498b8547b082cd2fac703ba8ace379d`.
Evidence: `C:\dev\perf\sideways-night-20261021\r35-120-release-summary.json`
and `r35-packaged-resources/runs/20261022T043549609039Z/result.json`.
Older executables and notices remain preserved. Actual one-player, four-player,
wet and mist export images were reviewed; the night log records their limits.

The existing 75% FSR2 option was then measured on the **same R35 executable**
in an adjacent native/75/75/native sequence, again four players and 1200/240
frames. Both native runs used scale1/mode0/TAA; both FSR2 runs used
scale0.75/mode2 without separate TAA. Output remains 3840Ã—2160 in both modes.

| R35 mode | Mean ms, two-run average | Mean of run p95s | Mean of run p99s |
| --- | ---: | ---: | ---: |
| Native 100% | 16.21150 | 21.5965 | 24.7425 |
| FSR2 75%, reconstructed 4K | 13.69457 | 16.3005 | 18.5500 |

FSR2 reduces mean frame cost by 15.53%; both paired mean/p95/p99 comparisons
improve, against -0.63% native-baseline drift. Percentiles above are averages
of per-run percentiles, not pooled samples. The FSR2 route-wall rates were
73.10 and 72.94 FPS, still below 120. Fresh one/four-player images show much
less horizontal crown smearing and clearer branches, with visible fine stipple
on paint/road/grass and harder roof/window edges. It is a quality tradeoff.
Native remained the default in R35. A matched 32-frame-per-mode clear4 sequence
(0.258 seconds first-to-last) retains the crown-smear reduction but also shows
persistent grid-like road grain and roof stipple. It passed only as an optional
quality tradeoff; subtle shimmer, tyre contact and route/weather-wide quality
are not established. Full evidence and boundaries are in the night log.
Evidence: `r35-fsr75-packaged-120-4/runs/bench-20261022T043903215186Z` and
`r35-fsr75-packaged-120-4/runs/shots-20261022T043628672807Z` under the same
night artifact directory.

## Historical native 4K baseline and protocol

First verified native run: Godot 4.5.2 Forward+ / Vulkan, RTX 5070 Ti,
Ryzen 9 5900X, four cars, vegetation auto. Raw evidence is
`C:\dev\perf\sideways-night-20261021\r05-native4k-baseline.log`.

| FPS | Mean ms | p95 ms | p99 ms |
| ---: | ---: | ---: | ---: |
| 35.045 | 28.53471 | 37.224 | 41.445 |

```text
godot --path . --resolution 3840x2160 --fullscreen --disable-vsync --fixed-fps 120 -- --benchmark 1200 --benchmark-warmup 240 --views 4 --rivals 0 --seed 4242 --at 300 --weather clear --km 2
```

Discard 240 warmup frames and measure 1200 frames: 2 + 10 simulation seconds.
Fixed FPS controls simulation advance, not measured wall-clock FPS. These
historical runs used 240 Hz physics. The round-05 to round-09
baselines used four tyre-solver substeps; incoming commit c74c161 changes this to two and also
shortens tree LOD distances. Treat the integrated version as a new baseline;
do not attribute that combined change to graphics caching alone. `--rivals 0` ensures exactly
four cars; bot-view runs otherwise add an extra rival. Run GPU comparisons
sequentially and use matched, unprofiled A/B repeats to decide performance.

The old layout kept four **958Ã—538** render targets even in a 4K window.
The native fix uses four **1916Ã—1076** targets at render scale **1.0**, with
8-pixel separators inside the 3840Ã—2160 output. Node2D origins preserve exact
render sizes through fractional canvas scaling while HUDs retain logical
coordinates. The headless regression covers 21 layouts and resize transitions.
Verify `root_output_size` and each viewport's size/scale in every benchmark.
Godot 4.5.2's `root_texture_reported_size` can misleadingly report 7680Ã—4320;
actual image readback establishes output size. Fullscreen avoids the observed
windowed-height clamp to 2119 pixels.

The diagnostic profile's opaque/depth-prepass GPU times are approximately
12.428/7.111 ms, averaged from reporting intervals, not exact frame-weighted
means. CPU script self time was 6.310 ms/frame. CPU and GPU work overlap:
do not add these figures or subtract GPU time from wall time to derive CPU
cost. Follow the night log for subsequent candidates and rejected experiments.

## Historical 1080p daytime results

The forest, car materials, weather, density of vegetation and close-up detail
are retained. The changes remove wasted distant geometry, avoid unused cliff
shading on flat ground, and fix invalid specular values that produced black
specks and bright blobs through TAA/bloom. The measurements below used the
earlier 1080p protocol; they are historical comparisons, not evidence for the
native 4K target or a minimum hardware specification.

Baseline: `25d8d7b`, with only the new benchmark instrumentation added.
Windows, Godot 4.5.2 Forward+ / Vulkan, RTX 5070 Ti, Ryzen 9 5900X,
1920Ã—1080 window, VSync disabled, vegetation auto. Other desktop applications
were running: use the results as local comparisons, not hardware minimums.

| Views | Before FPS | After FPS | Change | Before mean / p95 ms | After mean / p95 ms | Engine primitive counter before â†’ after |
| --- | ---: | ---: | ---: | --- | --- | --- |
| 1 | 69.22 | 78.59 | +13.5% | 14.45 / 18.48 | 12.72 / 17.18 | 12.68M â†’ 9.71M |
| 2 | 54.21 | 57.69 | +6.4% | 18.45 / 24.95 | 17.33 / 23.48 | 16.29M â†’ 13.56M |
| 4 | 36.40 | 37.66 | +3.5% | 27.47 / 37.23 | 26.56 / 37.40 | 34.87M â†’ 22.43M |

A second four-view before/after pair measured **35.72 â†’ 39.26 FPS**, with
p95 **36.83 â†’ 35.62 ms**. Timing varies; the 35.7% reduction in the engine's
primitive counter and 7.4% reduction in draw calls (3701 â†’ 3428) reproduced exactly.
The first four-view run did not improve p95/p99. Do not infer smoother worst
frames from the average FPS alone. Counts include render passes, not unique
scene geometry. Three-player timing has not been measured separately.

Later source audit corrected the interpretation of the primitive count:
[Godot 4.5.2's LOD counter](https://github.com/godotengine/godot/blob/4.5.2-stable/servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.cpp#L953-L975)
omits the instance-count multiplier in its mesh-LOD branch. Restoring
MultiMesh LODs therefore changes the accounting as well as the geometry.
The 35.7% is **not a verified hardware-triangle reduction**. Wall-clock
FPS and frame-time measurements are independent of that counter.

The historical protocol used seed 4242, started at 300 m, clear weather,
a 2 km stage, 120 warmup frames and 600 measured frames. `--fixed-fps 60`
fixes simulation advance and the bot route; elapsed
wall time supplies FPS. It does not cap the reported FPS at 60. These short
runs exclude stage loading and do not represent every part of every stage.
Car count, render cadence and resolution differ from the current protocol;
do not directly interpret their timings as native 4K before/after results.

## Historical 21 October changes

These describe the earlier procedural-grass/block-tree snapshot. Current
photo grass and per-view TreeSets supersede parts of that geometry and layout.

1. **Preserve imported prop LODs.** Translating rocks, ferns and stumps through
   SurfaceTool had discarded their LOD index buffers. One stump alone has
   about 41k full-detail triangles. Translation now preserves vertex order,
   both packed index widths, LOD errors and materials. Converted meshes are
   cached between stages. Roadside grass also shares duplicate vertices.
2. **Use cheaper geometry where it occupies few pixels.** The far grass rings
   retain five blades, their bounds, colours, density and wind, but use one
   segment instead of three. Near grass is unchanged. For three/four views,
   trees switch to the existing mid mesh at 26.25 m and impostors at 75 m,
   with the original dissolve widths. One/two-view tree ranges stay unchanged.
   This profile is selected when a stage is built.
3. **Keep lighting finite and avoid unused work.** The custom gravel specular
   term allowed `pow(0, 0)` and a zero-length halfway vector. Guarding both
   removes the observed black specks/bright blobs while retaining TAA, glow,
   SSAO and shadows. Flat terrain now skips cliff textures and cliff noise
   when the rock blend weight is exactly zero; rocky surfaces retain them.

An intermediate LOD/grass-only pass measured 80.04 / 56.80 / 36.88 FPS for
one/two/four views. The final changes were kept for their visual correctness
and lower four-view draw/geometry counts; individual shader speedups were
not isolated from measurement variance.

## Visual comparison and direction

These are art-direction comparisons with official material, not comparative
performance tests of the commercial games.

| Reference | Useful visual quality | Application to Sideways |
| --- | --- | --- |
| [EA SPORTS WRC](https://www.ea.com/games/ea-sports-wrc/wrc-24/news/wrc24-gameplay-deep-dive) | Convincing car surface contrast, readable reflections and environmental detail | Keep the car and wet gravel highlights stable; fix invalid lighting before adding effects. |
| [art of rally](https://www.artofrally.com/) | Clear road silhouette and controlled colour hierarchy | Preserve a readable route through the dense forest; distant blade bends contribute less than silhouette and tonal separation. |
| [DIRT 5](https://www.playstation.com/en-gb/games/dirt-5/) | Local split screen for up to four players | Judge detail at the actual quarter-screen size and budget all four cameras together. |

Godot's [MultiMesh documentation](https://docs.godotengine.org/en/stable/tutorials/performance/using_multimesh.html)
explains the remaining tradeoff: instances in a MultiMesh are culled as a
group. Larger blocks reduce submissions but can draw more invisible objects.

The historical 21 October matched screenshots used the same seed, camera, position, weather and tick
count before/after. Reviewed stationary two/four-view clear scenes, a moving
forest scene, two-view wet weather and four-view mist. Cars, vegetation
coverage, road shape and weather remain recognisable. The specular fix is a
visible improvement. Some foliage ghosting remains during motion with TAA;
turning TAA off reduced that but introduced aliasing, so that experiment was
not retained. Disabling SSAO, shadows, grass or particles did not fix the
original specks. An engine upgrade was not needed.

Local captures and raw logs are in `C:\dev\perf\sideways-20261021`:
`before-forest.png` / `after-forest.png`, `before-four.png` / `after-four.png`,
`after-wet.png`, `after-mist.png`, and `bench-*.log`. Images are review
artifacts and are not bundled into the game.

## Historical 21 October validation and remaining work

- Project import and per-script parsing passed (standalone checks exclude the
  known autoload-only `GameNight` identifier diagnostic).
- New geometry regression passed: 16/32-bit LOD indices, actual stump LODs,
  unchanged full-detail indices/materials, and near/far grass bounds. Added
  to CI.
- Handling bench passed. The 45,000-tick seed-1 simulation completed two
  stages with two finishes. GameNight lifecycle/controller-input checks passed.
- Windows release export passed, and the exported executable rendered the
  four-player scene successfully (`release-four.png`). The local executable
  is `C:\dev\sideways-graphics-20261021\build\Sideways.exe`.
- Existing headless dummy-renderer and exit resource warnings remain; passing
  assertions do not mean every log is warning-free.

The next performance work should separate physics, scene submission and GPU
cost on the intended minimum PC. The printed process/physics monitors are
[cached one-second maxima](https://github.com/godotengine/godot/blob/4.5.2-stable/main/main.cpp#L4399-L4533),
averaged by the old probe; they are not additive mean frame components.
The physics value describes a single tick, not all ticks in a drawn frame.
Profile vegetation block sizing and shared shadow
work, then evaluate motion stability in the tree impostors. Keep car and
near-road detail as the priority. Test longer, dispersed four-car races and
the intended minimum GPU before declaring a minimum specification or achieving
the current 120 FPS target. The daytime playtest log contains the current
integration and qualification state.
