# Kern: an engine built for fast iteration

Rust workspace for the Sideways port. Designed around the loops that cost an
AI (or a person) time: compiling, tuning numbers, seeing results, finding
why two runs differ, and comparing with the Godot original.

| Crate | What |
| --- | --- |
| `kern` | engine core: deterministic `Sim` trait, state digests, first-divergence finder, traces as compact tables, timings per system |
| `gdcompat` | bit-exact Godot 4 pieces: PCG32 (`seed`, `randi`, `randf`, `randf_range`), `hash()`, FastNoiseLite |
| `sideways` | the game simulation: stage, terrain, road, barriers, car physics (Rapier), AI, race loop |
| `render` | the renderer: cluster LOD DAG (Nanite-style), GPU culling, visibility buffer, HDR shading in physical units, canopy-volume GI, AgX; headless, renders into textures |
| `cli` | the `sideways` tool |

## Commands

    cargo run -p cli -- shot out.png --seed 1 --km 3 --at 300 --weather clear   # a race moment, offscreen
    cargo run -p cli -- shot out.png --views 4 --size 1920x1080                  # split screen
    cargo run -p cli -- shot out.png --pick 420,230                              # what covers that pixel
    cargo run -p cli -- shot out.png --set ev100=13.5 --set gi=0 --set debug=1   # retune light, A/B GI, sky visibility view
    cargo run -p cli -- gpu-run --out ../gpu-out                                 # gpu-jobs.toml (see GPU_RUNNER.md)
    cargo test -p render                                                         # every WGSL shader validated, no GPU

    cargo run -p cli -- bench                      # handling bench, next to Godot's numbers
    cargo run -p cli -- sim --ticks 45000 --seed 1 --km 2 --events
    cargo run -p cli -- sim --ticks 14000 --trace players.0.kmh,players.0.car.gear --from 12000 --every 30
    cargo run -p cli -- sim --ticks 13660 --probe 14.2,-166.0,1.5   # what colliders are there
    cargo run -p cli -- check /tmp/o.json --seed 1 --km 2           # compare with Godot

Car numbers live in `data/cars.toml` and are read at every run: retune and
rerun without rebuilding. `--cars other.toml` runs a variant.

The oracle for `check`:

    godot --headless --path .. --script res://tools/oracle_dump.gd -- --seed 1 --km 2 --out /tmp/o.json

## Parity with Godot

- Stage layout, rivers, pace notes, heights, terrain chunks, trees and the
  road ribbon match Godot exactly, for every seed tried.
- Handling bench: within about 1% (0-100 3.67 vs 3.68 s, braking 42.4 vs
  42.7 m, top speed 213.6 vs 213.6 km/h, handbrake turn 143 vs 143 degrees).
- `--sim 45000 --seed 1 --km 2`: the same four stages; 6 finishes either
  way, 6 vs 7 recoveries, 228 vs 210 shifts. Bit-equal driving is not a goal
  (Jolt versus Rapier), the behaviour is.

Things learned on the way, each one a trap for the next port:

- `randf()`, `randf_range()` and `RandomNumberGenerator.randf()` use three
  different algorithms in Godot 4.5.
- Every GPUParticles3D takes a draw from the global RNG when created.
- Godot's concave shapes are two-sided; Rapier's trimeshes are one-sided,
  so the ground's winding is flipped.
- Parry's shape casts lose precision against huge boxes (the bench's 6 km
  ground made the suspension bounce); a half-space is exact.

## The iteration loops, measured

On a 2-core cloud container:

| Loop | Rust (kern) | Godot |
| --- | ---: | ---: |
| type check after an edit | 0.4 s | (parse on load) |
| rebuild after an edit | 0.6-0.9 s | none |
| retune a number and rerun the bench | 0.07 s | 3.3 s |
| handling bench (82 s simulated) | 0.07 s | 3.3 s |
| generate a stage layout | 1 ms | ~2 s (with startup) |
| build a stage's colliders | 0.7 s | ~10 s (with meshes) |
| 45000-tick race sim (4 stages) | 16 s | 112 s |
| find why the car went missing | one `--trace`, one `--probe` | prints, rerun |
| validate all shaders | 2 s (`cargo test -p render`) | run the game |
| render a frame on the software GPU | 7 s | about 35 s |
| find what draws a wrong pixel | one `--pick x,y` | inspect the scene tree |

## The renderer

- **Geometry:** every mesh becomes clusters of up to 128 triangles in a LOD
  DAG (meshoptimizer's clusterlod: groups simplified with locked borders,
  so any cut is crack-free). Per frame a compute pass culls and LOD-selects
  clusters per instance against a 1 px error; a cluster is drawn when its
  own error is small enough and its group's coarser replacement is not.
  Trees: about 4000 triangles up close, about 150 far away.
- **Visibility buffer:** survivors are drawn as one indirect draw (one
  instance per cluster, vertices pulled from storage buffers) into an
  R32Uint target: which triangle covers each pixel. Alpha-tested foliage
  is cut there, with coverage-preserving mips so crowns stay dense far away.
- **Shading** happens once per pixel in a compute pass: the view ray is
  intersected with the triangle for exact barycentrics; light in physical
  units (sun in lux, the HDRI scaled to the sky's lux and turned to match
  the sun, SH9 irradiance), a texel-snapped sun shadow map drawn through the
  same cluster path, distance fog. Terrain and road shading are ports of
  Godot's terrain.gdshader and road.gdshader.
- **GI:** tree crowns and car bodies are splatted into a density volume
  around the cameras; with the terrain heightfield it gives sky visibility,
  sunlight through the canopy beyond the shadow map, and ground bounce.
- **HDR to screen:** exposure as EV100 (14 for clear weather, calibrated
  against Godot's frame), AgX, sRGB.
- **Split screen:** every view culled, rastered and shaded on its own, one
  shared shadow map, tonemapped into its rectangle.

Not there yet: grass and ground cover, car lights and particles, wet road
reflections, a window and input for playing. GPU numbers come from the
runner (GPU_RUNNER.md); the container only has a software rasteriser.
