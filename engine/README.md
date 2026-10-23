# Kern: an engine built for fast iteration

Rust workspace for the Sideways port. Designed around the loops that cost an
AI (or a person) time: compiling, tuning numbers, seeing results, finding
why two runs differ, and comparing with the Godot original.

| Crate | What |
| --- | --- |
| `kern` | engine core: deterministic `Sim` trait, state digests, first-divergence finder, traces as compact tables, timings per system |
| `gdcompat` | bit-exact Godot 4 pieces: PCG32 (`seed`, `randi`, `randf`, `randf_range`), `hash()`, FastNoiseLite |
| `sideways` | the game simulation: stage, terrain, road, barriers, car physics (Rapier), AI, race loop |
| `cli` | the `sideways` tool |

## Commands

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
