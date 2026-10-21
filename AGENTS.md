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
| `src/car_spec.gd` | numbers per car (mass, springs, torque curve, gears); `MODELS` are the grid cars, Rally2 numbers plus their own size and balance |
| `src/car_model.gd` | car looks: glTF body in the player's colour, knuckle (steers, carries the caliper) and spinner per wheel, tyres on `tyre.gdshader` (flatten under load), collision boxes from the body |
| `src/surfaces.gd` | grip per surface (gravel, loose, grass, dirt) |
| `src/stage.gd` | stage layout: centre line, heights, crests, ditches, ledges (rock wall and drop), streams (ford or bridge), pace notes |
| `src/stage_builder.gd` | terrain chunks, road ribbon (wheel tracks and gravel ridges are geometry), ground map, colliders, tree spots, walls and rails, water ribbons, bridges |
| `src/forest.gd` | trees per 24 m block: near mesh, mid mesh, impostor beyond 150 m, dithered dissolve between them (`lod_fade.gdshaderinc`) |
| `src/track_map.gd` | tyre marks for the whole stage in road space, read by the road shader |
| `src/ground_cover.gd` | grass tufts (built in code), ferns, mossy rocks and stumps (Poly Haven glTF in assets/props) |
| `src/wheel_fx.gd` | dust and flying gravel from the rear wheels, spray in water |
| `src/canopy.gd` | forest shade map: a soft shadow per tree drawn once on the GPU; ground, road and grass darken the sun by it (`canopy.gdshaderinc`) |
| `src/grass_field.gd` | ground cover: near and far grass carpets and berry shrubs, MultiMesh grids the shader moves with whichever camera draws them, standing on the ground map (setting `vegetation` auto/high/medium/low; auto steps down per split-screen view) |
| `src/shaders/relief.gdshaderinc` | hummocks and rock knobs added in the vertex shader within 13 m of the road; the terrain cells there are split 3x3 (`StageBuilder.SPLIT`), colliders stay on the 2 m grid |
| `src/door_sticker.gd` | the driver's face and name on the doors (decals) and the first six letters on the rear plate (filled from font outlines: atlas glyphs render as boxes on lavapipe) |
| `src/car_lights.gd` | headlights and brake glow as real lights, brighter in dark weather |
| `src/perf_probe.gd` | `--perf`: fps, script and physics ms, per-view CPU/GPU ms every 2 s |
| `src/backfire.gd` | exhaust pops on high-rev downshifts and lifts (visual only, own RNG) |
| `src/shaders/mud.gdshader` | mud overlay on body and tyres; `Car.dirt` grows with distance on loose ground and in water (`--dirt 0..1` for shots) |
| `src/ai.gd` | bot driver (pure pursuit + speed plan) |
| `src/hud.gd`, `src/chase_camera.gd` | per-player instruments and camera |
| `tests/bench.gd` | handling bench: 0-100, top speed, braking, skidpad, handbrake turn |

## The driving model

The ingame `VehicleBody3D` is not used. `Car` is a `RigidBody3D` with our own
forces in `_integrate_forces`: per wheel a cylinder cast along the axle, spring, damper, bump stop and
anti-roll bar; a combined-slip Pacejka tyre whose slip is a relaxation-length
state; wheels, engine and couplings in two substeps per 240 Hz tick, with
clutch and diffs solved implicitly. The handbrake opens the centre coupling.
Change a number, then run the bench and compare.

## Check every change

    godot --headless --import
    tools/check.sh                                               # parse errors per script
    godot --headless --path . --fixed-fps 240 --script res://tests/bench.gd
    godot --headless --fixed-fps 240 --path . -- --sim 45000 --seed 1 --km 2
    python3 tests/lifecycle.py --godot godot                     # needs websockets

A script with a parse error makes headless runs hang instead of failing.
Untyped values from Dictionaries (`spec.x`) need an explicit type: `var a: float = spec.x`.

## See it without a person

`tools/shot.sh out.png --frames 30 --seed 1 --at 300 --cam chase` renders
one frame with the real renderer on lavapipe. Every drawn frame costs about
35 s there, so the 3D views stay off until the last `--render N` frames
(default 2; particles want 8 or more). `--frames` counts physics ticks
(240 a second): `--frames 1600` is about 3 s into the stage after the
countdown. `--menu` shows the Start menu. `--views 2`
shows split screen with bot drivers. `GAME_TRACE=1` prints what happens;
`GAME_DEBUG=1` prints car state twice a second.

## Cars

`assets/cars/*.glb` come from Sketchfab (CC BY, see CREDITS.md), cleaned up in
Blender: one `body` mesh, and per corner `wheel_FL` .. `wheel_RR` and
`caliper_*` with their origin at the wheel centre, forward is -Z, y = 0 at
the hub. A node name may carry a suffix like `_002`. Paint is the surface
whose material name holds `Bodymat` or `Paint`; tyre surfaces hold `Tire`.
A new car needs those names, an entry in `CarSpec.MODELS` with its measured
wheelbase, track and wheel radius, and a credit.

## Light and weather

`Look.weather()` sets one of clear, overcast, mist, wet per stage (the
`weather` setting, random by default; `--weather` forces one). With a sky as
ambient source the ambient energy does nothing unless the sky contribution is
below 1, so `_ambient()` sets both. The sun sits across the stage's general
heading so trees shade the road; the HDRI is turned to match. Ground, road and
grass shaders have their own `light()` (Lambert, plus a glint on the road) so
the canopy map can dim the sun; `wetness` is a global shader parameter.

## Trees

The forest combines retained Poly Haven `fir_tree_01` wood (CC0) with authored
Pine Tree crowns by evolveduk (CC BY 4.0; see CREDITS.md). Two separate offline
workflows exist. `tools/thin_tree.py -> tools/bake_trees.gd` remains the original
Poly Haven whole-tree generator and will regenerate its original twig cards.
`tools/build_pine_crowns.gd` is an explicit additional crown-replacement step,
using hash-pinned data and instructions in `tools/pine_crown_data/`. It writes only
a fresh `res://build/<name>` candidate directory and preserves all packed non-twig
surfaces. Validate the six candidate meshes in an isolated checkout before
promoting. Rebuild matching 8-view albedo/normal impostor atlases with
`tools/bake_impostors.gd` after any accepted crown change; never mix atlases from
one crown set with near/mid meshes from another. Keep the CC BY attribution with
any distributed assets. The raw builder data under tools/ are excluded from the
runtime export by the existing preset.

## Rules

- Start playing at once; no setup screen before the first stage.
- Controls: RT throttle, LT brake, A handbrake, X back on the road, Y camera,
  RB/LB gears only with the manual gearbox (an explicit menu choice). The Start
  menu shows a Controls panel beside it (Joep asked for it).
- Car contact is on by default; a reset car is a ghost until it is clear.
- Every option is a GameNight setting (`SETTINGS` in main.gd) and sits in the
  Start menu. The menu shows the title, Resume, New stage, then settings,
  with no button hints in the menu itself. Never bind Back.
- Deterministic: global RNG seeded from `--seed`, simulation in `_physics_process`.
- Push to main. Assets: Poly Haven (CC0) textures and sky; credits in CREDITS.md.
