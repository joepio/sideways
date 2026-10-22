# Graphics performance — 21 October 2026

The current target is **120 FPS with four players at native 3840×2160**:
8.33 ms per frame. **This target has not been reached.** Later experiments,
visual decisions and validation are recorded in the
[night iteration log](graphics-night-2026-10-21.md).

## Current validation basis — 22 October, 120 Hz / four substeps

The current source and R33 executable use 120 physics ticks per second and
four tyre-solver substeps, introduced by incoming commit `85b5e72`. Preserve
this basis in subsequent comparisons; the earlier 240 Hz results below are
historical. R33 has passed the full handling, 45,000-tick simulation and
lifecycle checks, with exact deterministic results matched to that incoming
baseline. Its packaged native four-player route measured:

| Build | Mean ms | p95 ms | p99 ms | Route wall-clock FPS |
| --- | ---: | ---: | ---: | ---: |
| R33, 120 Hz / four substeps | 19.35517 | 27.251 | 28.206 | 51.6658 |

This is a fixed-route comparison, not a claim about typical gameplay FPS.
The 8.33 ms target remains unmet. Use `--render-scale 100%` explicitly and
verify the actual output and all four viewport sizes. Current candidates
and their independent timing/visual evidence remain in the night log until
they pass integrated validation and a new packaged build.

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

The old layout kept four **958×538** render targets even in a 4K window.
The native fix uses four **1916×1076** targets at render scale **1.0**, with
8-pixel separators inside the 3840×2160 output. Node2D origins preserve exact
render sizes through fractional canvas scaling while HUDs retain logical
coordinates. The headless regression covers 21 layouts and resize transitions.
Verify `root_output_size` and each viewport's size/scale in every benchmark.
Godot 4.5.2's `root_texture_reported_size` can misleadingly report 7680×4320;
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
1920×1080 window, VSync disabled, vegetation auto. Other desktop applications
were running: use the results as local comparisons, not hardware minimums.

| Views | Before FPS | After FPS | Change | Before mean / p95 ms | After mean / p95 ms | Engine primitive counter before → after |
| --- | ---: | ---: | ---: | --- | --- | --- |
| 1 | 69.22 | 78.59 | +13.5% | 14.45 / 18.48 | 12.72 / 17.18 | 12.68M → 9.71M |
| 2 | 54.21 | 57.69 | +6.4% | 18.45 / 24.95 | 17.33 / 23.48 | 16.29M → 13.56M |
| 4 | 36.40 | 37.66 | +3.5% | 27.47 / 37.23 | 26.56 / 37.40 | 34.87M → 22.43M |

A second four-view before/after pair measured **35.72 → 39.26 FPS**, with
p95 **36.83 → 35.62 ms**. Timing varies; the 35.7% reduction in the engine's
primitive counter and 7.4% reduction in draw calls (3701 → 3428) reproduced exactly.
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

## Daytime changes retained

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

Matched screenshots used the same seed, camera, position, weather and tick
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

## Daytime validation and remaining work

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
the current 120 FPS target. The night log contains the current validation state.
