# Handoff: Kern engine (Sideways port)

For the next agent. Read this, then `README.md` (commands, parity, renderer)
and `../AGENTS.md` (the Godot game this ports). Branch: `rust-engine`.
`main` is the Godot game; do not touch it.

## Goal

Joep asked for an engine designed around fast AI iteration loops, with the
Sideways rally game (Godot 4.5) as the benchmark: port it, and beat Godot
on graphics, physics and developer velocity. Modern rendering from the
start: Nanite-style cluster LOD, visibility buffer, HDR in physical units,
GI. Keep the loops short and measured (README, "The iteration loops").

## Rules from Joep

- Talk to him in Dutch, without em-dashes. Code, comments and docs in English.
- **Never open windows on his screen or take it over** (he may be watching
  a film on that PC). Everything renders offscreen: `shot` writes a PNG,
  `gpu-run` writes results. Do not add a windowed mode that opens by itself.
- Commit to `rust-engine` and push. End commit messages with:

      Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
      Claude-Session: https://claude.ai/code/session_01J41A9knfrMNAChGX8fzLhc

  (use your own session link if you have one)
- When mentioning PRs, link them with a short description.
- Show him pictures of what changed. Compare against Godot's frame at the
  same moment, and be honest about what still looks worse.

## Where it stands (commit 3f930b8)

- Simulation: stage, terrain, road, barriers, cars (Rapier), AI and race
  loop ported. Stage layout matches Godot bit for bit; handling bench is
  within about 1%. See README "Parity".
- Renderer (`crates/render`), all headless wgpu 30:
  - cluster LOD DAG (meshopt clusterlod) and GPU cull;
  - visibility buffer and compute shading;
  - sun shadow map (cached while nothing moves) and canopy-volume GI;
  - TAA plus CAS sharpening;
  - textures: 2K albedo and 1K normal-map arrays, sampled with
    ray-differential gradients and 16x anisotropic filtering;
  - materials: GGX, sky reflections, clear-coat paint, Godot's foliage look.
- Joep's last verdict before the latest fixes: "very pixelated, especially
  the trees, ground and wall very blurred". That is fixed now: TAA,
  anisotropic gradients, normal maps.
- The cloud container only had lavapipe (CPU), about 40 s for a 16-frame
  TAA shot. On Windows you have a real GPU: use it, the loop should be
  milliseconds.

## Setup on Windows

    winget install Rustlang.Rustup LLVM.LLVM Git.Git
    rustup default stable
    git clone https://github.com/joepio/sideways && cd sideways && git checkout rust-engine
    cd engine
    cargo test -p render          # shader validation, no GPU
    cargo run --release -p cli -- shot out.png --seed 1 --km 3 --at 300 --weather clear --size 1920x1080

`engine/.cargo/config.toml` sets clang + lld for Linux. If linking fails on
Windows, scope that config to the Linux target (or use `rust-lld`). Do not
just delete it: the Linux container needs it.

`KERN_ADAPTER` picks a GPU adapter by name substring. The shot prints the
adapter and per-pass GPU ms from timestamp queries. `gpu-run` (see
GPU_RUNNER.md) runs `gpu-jobs.toml`. The polling runner described there is
not needed now that you run on the GPU machine itself.

Godot reference frame: `tools/shot.sh out.png --frames 30 --seed 1 --at 300
--cam chase` from the repo root (needs Godot 4.5 in PATH). It renders
offscreen.

## In progress: grass and ground cover (Joep said yes)

This is the biggest visible gap with Godot: the verge is bare, with a
mown-lawn tiling, where Godot has grass tufts and berry shrubs. Port
`src/grass_field.gd` and its shaders (`grass_cards.gdshader`,
`grass_field.gdshader`, `vegetation_density.gdshaderinc`,
`grass_coverage.gdshaderinc`), plus `src/ground_cover.gd` (ferns, mossy
rocks, stumps; the chunks already carry `ferns`, `rocks`, `stumps` and
`grass` spots in `builder.rs`).

What Godot does:

- **Carpets.** Rings of tufts around each camera, built on a world-cell
  grid with `[kind, cell, inner, radius, grow]`:
  - high detail: grass at (0.3 m, 0-20 m), (0.7 m, 18-60 m) and
    (1.6 m, 52-110 m); shrubs at (0.55 m, 0-30 m);
  - medium and low presets for 2 and 3-4 views.
- **Placement per cell id.**
  - jitter: `(hash(id), hash(id+17)) - 0.5) * 1.6` cells;
  - size: `grow * mix(0.7, 1.3, hash(id+9))`;
  - angle: `hash(id+3) * 2π`;
  - hash: `fract(sin(dot(p, (127.1, 311.7))) * 43758.5453)`.
- **Density, from the ground map** (height, metres from road edge, normal Y):
  - grass = `max(verge, wood) * (1 - shade * 0.45) * level`, where:
    - verge = `smoothstep(0.5, 1.4, d) * (1 - smoothstep(10, 22, d))`;
    - wood = `smoothstep(0.3, 0.6, noise(xz/7)) * 0.85 * smoothstep(1, 3, d)`;
    - level = `smoothstep(0.7, 0.82, up)`.
  - shrubs: patch noise, times `smoothstep(2.5, 6, d) * (0.7 + shade * 0.5)`.
  - `shade` is Godot's canopy map (a soft shadow per tree). Approximate it
    from tree spots, or from our canopy volume.
- **Coverage.** Each tuft is dissolved by a fixed per-tuft hash pattern
  (`grass_coverage_sample`), with smooth ring crossfades.
- **Grass mesh.** 3 crossing cards, 0.50 m high and
  `0.36*(257/135)` m wide. The UV is an atlas sub-rect of
  `assets/grass/grass_medium_01_diff_2k.jpg`, with the alpha in
  `grass_medium_01_alpha_2k.png` (red channel); combine them into one RGBA
  layer. Atlas min `(580.5, 889.5)/1024`, max `(836.5, 1023.5)/1024`,
  v flipped.
  - albedo: `tex * mix(0.8, 1, h) * 1.25`, normal straight up;
  - AO: `mix(0.45, 1, h) * (1 - canopy * 0.5)`;
  - translucency: `(0.12, 0.16, 0.05) * max(-n·l, 0)`.
- **Shrub mesh.** Procedural, `_shrub()`: 4 twigs × 6 leaves, RNG seed 11.
  - colour: `mix(green, dry, smoothstep(0.5, 0.75, tone))`, with green
    (0.2, 0.32, 0.1), dry (0.52, 0.15, 0.07) and
    `tone = noise(xz/5)*0.6 + hash(id+2)*0.4`;
  - Godot colours are sRGB: convert them to linear.
- **Wind.** Tips sway; there is no time in shots yet, so it can wait.

Plan I had for Kern:

- **First step: build the tufts as instances on the CPU around the
  cameras, in `cli/src/visuals.rs`.** Make the decision for a fractional
  coverage per tuft: keep a tuft when `hash < coverage`.
  - Each tuft is one tiny cluster, so ~60k instances is fine for the cull.
  - This needs a heightfield with road distance and normal Y: extend
    `heightfield()` (the chunks have `heights` and `road_d`).
  - Add material flags for grass cards and shrubs. In `shade.wgsl`, derive
    tuft height from the instance origin (`inst.r1.w`) and `inst.scale`,
    and per-tuft tone from the instance origin.
- **Right final design: GPU-driven.** A compute pass spawns the visible
  tufts per view into the instance or visible list, so the CPU does nothing
  per frame and split screen is free. Do it once the scene can move.

## After that

- **Per-instance motion vectors for TAA.** Only camera motion is
  reprojected now, so moving cars would smear. Shade knows the instance;
  keep a previous-transform buffer and write velocity.
- **A playable loop.** Cars move every frame (instance updates, shadow
  invalidation), input, a window. The window must only open when Joep
  starts it himself.
- **Visual differences with Godot that remain:**
  - distant forest denser and darker than Godot's (Godot uses mid meshes
    and impostors beyond 150 m, `src/forest.gd`);
  - canopy GI darkens crowns a lot (try `--set gi=0`);
  - the rock wall's vertical streaks come from a faithful port of Godot's
    terrain shader; full triplanar would fix them in both.
- **Also from the game:** car lights, dust and gravel particles, wet roads,
  tyre marks (`track_map.gd`).
- **Performance on the real GPU:** measure with `gpu-run`. Shadow raster
  was the heaviest pass on lavapipe. Sim cost: Rapier step 175 µs and car
  forces 120 µs per tick.

## Handy

- `shot --pick x,y` says which instance, mesh, cluster and triangle covers
  a pixel.
- `--set key=value` retunes `Lighting` without rebuilding:
  - light and look: ev100, sun_lux, sky_lux, sun_elevation, fog_*, gi,
    debug=1 (sky visibility), debug=2 (albedo);
  - TAA: taa, taa_blend, taa_gamma, sharpen;
  - foliage: alpha_cut.
- `--taa 1` gives one frame without TAA.
- Every new WGSL file goes in the `shaders_validate` test in `render/src/lib.rs`.
- Traps already hit are listed in README. Two more:
  - In the view uniform, `params.z` is the ortho flag for culling; the alpha
    threshold lives in `extra.x`.
  - `shot` takes the output path positionally; it has no `--out`.
