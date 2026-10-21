# Graphics iteration — 21 October 2026

The forest, car materials, weather, density of vegetation and close-up detail
are retained. The changes remove wasted distant geometry, avoid unused cliff
shading on flat ground, and fix invalid specular values that produced black
specks and bright blobs through TAA/bloom. Four-player split screen works, but
these measurements do **not** establish a 60 FPS budget on low-end hardware.

## Measured result

Baseline: `25d8d7b`, with only the new benchmark instrumentation added.
Windows, Godot 4.5.2 Forward+ / Vulkan, RTX 5070 Ti, Ryzen 9 5900X,
1920×1080 window, VSync disabled, vegetation auto. Other desktop applications
were running: use the results as local comparisons, not hardware minimums.

| Views | Before FPS | After FPS | Change | Before mean / p95 ms | After mean / p95 ms | Triangles before → after |
| --- | ---: | ---: | ---: | --- | --- | --- |
| 1 | 69.22 | 78.59 | +13.5% | 14.45 / 18.48 | 12.72 / 17.18 | 12.68M → 9.71M |
| 2 | 54.21 | 57.69 | +6.4% | 18.45 / 24.95 | 17.33 / 23.48 | 16.29M → 13.56M |
| 4 | 36.40 | 37.66 | +3.5% | 27.47 / 37.23 | 26.56 / 37.40 | 34.87M → 22.43M |

A second four-view before/after pair measured **35.72 → 39.26 FPS**, with
p95 **36.83 → 35.62 ms**. Timing varies; the 35.7% reduction in submitted
triangles and 7.4% reduction in draw calls (3701 → 3428) reproduced exactly.
The first four-view run did not improve p95/p99. Do not infer smoother worst
frames from the average FPS alone. Counts include render passes, not unique
scene geometry. Three-player timing has not been measured separately.

Reproduce with the command in [README](../README.md). Each run uses seed 4242,
starts at 300 m, clear weather, a 2 km stage, 120 warmup frames and 600 measured
frames. `--fixed-fps 60` fixes simulation advance and the bot route; elapsed
wall time supplies FPS. It does not cap the reported FPS at 60. These short
runs exclude stage loading and do not represent every part of every stage.

## Iterations retained

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

## Validation and remaining work

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
cost on the intended minimum PC. Four-view logs still show substantial CPU
physics time as well as thousands of draws; reducing triangles alone does
not solve that budget. Profile vegetation block sizing and shared shadow
work, then evaluate motion stability in the tree impostors. Keep car and
near-road detail as the priority. Test longer, dispersed four-car races and
the lowest supported GPU before declaring a minimum specification or 60 FPS.
