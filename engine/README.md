# Kern: an engine built for fast iteration

Rust workspace for the Sideways port. Designed around the loops that cost an
AI (or a person) time: compiling, tuning numbers, seeing results, finding
why two runs differ, and comparing with the Godot original.

| Crate | What |
| --- | --- |
| `kern` | engine core: deterministic `Sim` trait, state digests, first-divergence finder, traces as compact tables, timings per system |
| `gdcompat` | bit-exact Godot 4 pieces: PCG32 (`seed`, `randi`, `randf`, `randf_range`), `hash()`, FastNoiseLite |
| `sideways` | the game simulation: stage layout, terrain chunks, road ribbon, barriers |
| `cli` | the `sideways` tool |

## Check against Godot

    godot --headless --path .. --script res://tools/oracle_dump.gd -- --seed 1 --km 2 --out /tmp/o.json
    cargo run -p cli -- check /tmp/o.json --seed 1 --km 2

Stage layout, rivers, pace notes, heights, terrain chunks, trees and the
road ribbon match Godot exactly (to Godot's JSON print precision) for every
seed tried. The Rust stage takes about 1 ms; the Godot oracle about 2 s.
