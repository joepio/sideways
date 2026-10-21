# Sideways

A gravel rally game for [GameNight](https://gamenight.ontola.io), with up to
four drivers racing the same forest stage in local split screen.

Controls: left stick steers, RT accelerates, LT brakes, A is the handbrake,
X resets and Y changes camera. Run it with Godot 4.5:

    godot --path . -- --players 2

See [AGENTS.md](AGENTS.md) for tests, screenshots and releases.

For a repeatable graphics benchmark, use the real renderer (not headless):

```sh
godot --path . --resolution 1920x1080 --windowed --disable-vsync --fixed-fps 60 -- --benchmark 600 --views 4 --seed 4242 --at 300 --weather clear --km 2
```

This drives the same route, warms up 120 rendered frames, then measures 600
frames using wall time and exits. The final `benchmark` JSON reports average
FPS, median/p95/p99 frame times, draw calls and rendered triangles. Repeat
with `--views 1` and `--views 2`; `--strip grass`, `--strip cover`, etc. isolate
costs. Keep the engine, hardware, resolution and other running apps the same.
Run `godot --headless --path . --script res://tests/graphics.gd` to check that
prop LOD indices and materials survive placement and grass retains its bounds.

See the [graphics iteration report](docs/graphics-performance.md) for measured
before/after results, visual references and remaining split-screen limits.
