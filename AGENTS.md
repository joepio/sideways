# Working on Sideways

A realistic gravel rally game for GameNight, in Godot 4.5 (Forward+, Jolt
physics). Up to four players drive the same stage at once in split screen.
The GameNight game playbook is the general guide:
https://gamenight.ontola.io/docs/playbook

## Where things are

| File | What |
| --- | --- |
| `main.gd` | GameNight lifecycle, players, stage rounds, split screen, Start menu, flags |
| `src/car.gd` | the car simulation: suspension, Pacejka tyres, engine, clutch, gearbox, diffs |
| `src/car_spec.gd` | numbers per car (mass, springs, torque curve, gears) |
| `src/surfaces.gd` | grip per surface (gravel, loose, grass, dirt) |
| `src/stage.gd` | stage layout: centre line, heights, crests, ditches, pace notes |
| `src/stage_builder.gd` | terrain chunks, road ribbon, colliders, tree spots |
| `src/forest.gd` | trees per 48 m block: near mesh, mid mesh, impostor beyond 120 m |
| `src/ai.gd` | bot driver (pure pursuit + speed plan) |
| `src/hud.gd`, `src/chase_camera.gd` | per-player instruments and camera |
| `tests/bench.gd` | handling bench: 0-100, top speed, braking, skidpad, handbrake turn |

## The driving model

The ingame `VehicleBody3D` is not used. `Car` is a `RigidBody3D` with our own
forces in `_integrate_forces`: per wheel a ray, spring, damper, bump stop and
anti-roll bar; a combined-slip Pacejka tyre whose slip is a relaxation-length
state; wheels, engine and couplings in four substeps per 240 Hz tick, with
clutch and diffs solved implicitly. The handbrake opens the centre coupling.
Change a number, then run the bench and compare.

## Check every change

    godot --headless --import
    tools/check.sh                                               # parse errors per script
    godot --headless --path . --fixed-fps 240 --script res://tests/bench.gd
    godot --headless --fixed-fps 240 --path . -- --sim 30000 --seed 1 --km 2
    python3 tests/lifecycle.py --godot godot                     # needs websockets

A script with a parse error makes headless runs hang instead of failing.
Untyped values from Dictionaries (`spec.x`) need an explicit type: `var a: float = spec.x`.

## See it without a person

`tools/shot.sh out.png --frames 30 --seed 1 --at 300 --cam chase` renders
one frame with the real renderer on lavapipe (slow, minutes). `--views 2`
shows split screen with bot drivers. `GAME_TRACE=1` prints what happens;
`GAME_DEBUG=1` prints car state twice a second.

## Trees

The forest is Poly Haven's `fir_tree_01`. `tools/thin_tree.py` thins it into
three variants and two levels of detail, `tools/bake_trees.gd` turns them into
`assets/trees/fir_*_{near,mid}.res`, and `tools/bake_impostors.gd` renders
the 8-view impostor atlases. Rerun those after changing the tree.

## Rules

- Start playing at once; no setup screen before the first stage.
- Every option is a GameNight setting (`SETTINGS` in main.gd) and sits in the
  Start menu. The menu shows the title, Resume, New stage, then settings,
  with no button hints. Never bind Back.
- Deterministic: global RNG seeded from `--seed`, simulation in `_physics_process`.
- Push to main. Assets: Poly Haven (CC0) textures and sky; credits in CREDITS.md.
