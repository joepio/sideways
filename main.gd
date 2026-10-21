extends Node
## Sideways: a gravel rally stage, everyone on it at once, split screen.
##
## Each round is one stage: a countdown, then everyone drives the same road
## (cars bump into each other unless car contact is off), times on the finish, a short result,
## then the next stage. Bots drive empty seats and AI rivals.
##
##   godot --path . -- --seed 7 --players 2        play standalone, 2 local pads
##   godot --path . -- --shot out.png --frames 600 bots drive; save a frame and quit
##   godot --headless --fixed-fps 240 --path . -- --sim 30000 --seed 1
##                                                 bots drive a stage; checks it, prints a state hash
## Extra flags: --at METRES (start that far into the stage), --cam chase|bonnet|far|side|top,
## --km N (stage length), --views N (split screen with N bot views), --menu (shot of the Start menu).
## --weather clear|overcast|mist|wet picks the weather instead of the setting.
## --dirt 0..1 starts the cars that muddy. --vegetation auto|high|medium|low.
## --render-scale auto|100%|75%|67%|50% draws the 3D smaller and upscales it with FSR 2.
## --rivals 0..3 overrides extra AI cars (use 0 for a four-player benchmark).
## --perf prints wall fps, cached CPU peak monitors and per-view GPU times every two seconds.
## --benchmark N measures N rendered frames after 120 warmup frames, then quits.
## --benchmark-warmup N overrides warmup frames (default 120).
## For a repeatable 120 Hz route: --fixed-fps 120 --disable-vsync with
## --benchmark 1200 --benchmark-warmup 240 measures 10 s after 2 s of warmup.
## --strip trees,cover,grass,terrain,shadows,ssao,glow,msaa,fog leaves those out (for --perf runs).
## With GAME_TRACE=1 the game prints what happens (tests/lifecycle.py reads it).
##
## Determinism: all randomness comes from the global RNG, seeded once from
## --seed; the simulation only moves in _physics_process.

const FACE := preload("res://addons/gamenight/face.gd")
const COUNTDOWN := 3.0
const RESULTS_SECONDS := 9.0
const FINISH_GRACE := 40.0
const RECOVER_PENALTY := 5.0
## After a reset a car is a ghost until it is clear of the others.
const GHOST_SECONDS := 2.0
const COLORS := [Color("#d8342c"), Color("#2f6fd6"), Color("#e8b21f"), Color("#2fa35a"),
	Color("#8a4fd1"), Color("#e46c1c"), Color("#d94f9a"), Color("#8c969e")]
const NAMES := ["Red", "Blue", "Yellow", "Green", "Purple", "Orange", "Pink", "Grey"]

## Declared to GameNight; the app, an LLM or the Start menu change them.
const SETTINGS := [
	{"key": "gearbox", "label": "Gearbox", "kind": "choice", "default": "automatic", "options": ["automatic", "manual"]},
	{"key": "stage_km", "label": "Stage length km (next stage)", "kind": "number", "default": 3, "min": 2, "max": 8},
	{"key": "rivals", "label": "AI rivals (next stage)", "kind": "number", "default": 1, "min": 0, "max": 3},
	{"key": "contact", "label": "Car contact (next stage)", "kind": "toggle", "default": true},
	{"key": "weather", "label": "Weather (next stage)", "kind": "choice", "default": "random", "options": ["random", "clear", "overcast", "mist", "wet"]},
	{"key": "vegetation", "label": "Vegetation (next stage)", "kind": "choice", "default": "auto", "options": ["auto", "high", "medium", "low"]},
	{"key": "render_scale", "label": "Render scale", "kind": "choice", "default": "100%", "options": ["auto", "100%", "75%", "67%", "50%"]},
]
var settings := {"gearbox": "automatic", "stage_km": 3, "rivals": 1, "contact": true, "weather": "random", "vegetation": "auto", "render_scale": "100%"}
var environment: Environment
var sun: DirectionalLight3D
var weather := "clear"

var players: Array[Dictionary] = []
var stage: Stage
var tracks: TrackMap ## tyre marks on the gravel
var world: Node3D
var stage_root: Node3D
var views_root: Control
var overlay: Control
var phase := "countdown"
var clock := 0.0
var results := 0.0
var first_finish := -1.0
var round_number := 0
var menu_owner := -1
var menu_row := 0
var host_paused := false
var session := ""
var stats := {"stages": 0, "finishes": 0, "shifts": 0, "recoveries": 0, "airtime": 0.0, "slides": 0.0}

var seed_value := 0
var standalone_players := 1
var shot := ""
var shot_frames := 600
var sim_frames := 0
var start_at := 0.0
var menu_from := Vector3.ZERO ## where the menu owner's car was when the menu opened
var shot_render := 2 ## --render N: play the last N drawn frames at normal speed (particles need a few)
var shot_menu := false ## --menu: the shot shows the Start menu
var cam_override := ""
var weather_override := ""
var perf: PerfProbe ## --perf
var strip: PackedStringArray = [] ## --strip: what to leave out, to find what a frame costs
var building := false ## a new stage is being built behind a cover
var dirt_override := -1.0
var km_override := 0.0
var bot_views := 0
var frame := 0
var trace := OS.get_environment("GAME_TRACE") == "1"
var faces := FACE.new()


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		var next: String = args[i + 1] if i + 1 < args.size() else ""
		match args[i]:
			"--seed": seed_value = int(next)
			"--players": standalone_players = int(next)
			"--shot": shot = next
			"--frames": shot_frames = int(next)
			"--sim": sim_frames = int(next)
			"--at": start_at = float(next)
			"--cam": cam_override = next
			"--weather": weather_override = next
			"--dirt": dirt_override = float(next)
			"--vegetation": settings.vegetation = next
			"--render-scale": settings.render_scale = next
			"--rivals": settings.rivals = clampi(int(next), 0, 3)
			"--perf":
				if perf == null:
					perf = PerfProbe.new()
			"--benchmark":
				if perf == null:
					perf = PerfProbe.new()
				perf.benchmark_frames = maxi(1, int(next))
			"--benchmark-warmup":
				if perf == null:
					perf = PerfProbe.new()
				perf.benchmark_warmup = maxi(0, int(next))
			"--strip": strip = next.split(",")
			"--km": km_override = float(next)
			"--views": bot_views = int(next)
			"--menu": shot_menu = true
			"--render": shot_render = int(next)
	if seed_value != 0:
		seed(seed_value)
	else:
		randomize()
	if perf:
		add_child(perf)
	_build_scene()
	get_viewport().size_changed.connect(_arrange_views)
	get_viewport().size_changed.connect(_apply_render_scale)
	if OS.get_environment("GAME_DEBUG") == "1":
		var d: Node = load("res://tools/dbg.gd").new()
		add_child(d)
	var benchmarking := perf != null and perf.benchmark_frames > 0
	if GameNight.launched_by_daemon and shot == "" and sim_frames == 0 and not benchmarking:
		GameNight.daemon_connected.connect(func(): GameNight.declare_settings(SETTINGS))
		GameNight.setting_changed.connect(_on_setting)
		GameNight.prepared.connect(_on_prepared)
		GameNight.started.connect(func(_s): _set_paused(false))
		GameNight.resumed.connect(func(_s): _set_paused(false))
		GameNight.paused.connect(func(_s): _set_paused(true))
		GameNight.disposed.connect(_on_disposed)
		GameNight.players_updated.connect(_on_players_updated)
		host_paused = true
		return
	var bots := shot != "" or sim_frames > 0 or benchmarking
	var roster: Array = []
	var humans := 0 if bots else maxi(1, standalone_players)
	if bots:
		humans = 0
	var views := maxi(humans, bot_views if bot_views > 0 else (1 if bots else 0))
	for i in views:
		roster.append({"bot": i >= humans, "seat": -1, "pad": i})
	_seat(roster)
	_new_stage()


func _build_scene() -> void:
	world = Node3D.new()
	world.name = "World"
	add_child(world)
	var env := WorldEnvironment.new()
	environment = Look.environment()
	env.environment = environment
	world.add_child(env)
	sun = Look.sun()
	world.add_child(sun)
	views_root = Control.new()
	views_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	views_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(views_root)
	overlay = Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.draw.connect(_draw_overlay)
	add_child(overlay)


func _on_prepared(session_id: String, seats: Array, profiles: Array) -> void:
	session = session_id
	var roster: Array = []
	for seat in seats:
		var occupant: Dictionary = seat.get("occupant", {})
		var kind := str(occupant.get("kind", "empty"))
		if kind != "local" and kind != "ai":
			continue
		var entry := {"bot": kind == "ai", "seat": int(seat.get("index", 0)), "pad": -1}
		for p in profiles:
			if str(p.get("id", "")) != "" and str(p.get("id")) == str(occupant.get("player_id", "")):
				entry.name = str(p.get("name", ""))
				entry.profile = p
				if p.has("color"):
					entry.color = Color.from_string(str(p.color), Color.WHITE)
		roster.append(entry)
	if roster.is_empty():
		roster.append({"bot": true, "seat": -1, "pad": -1})
	_seat(roster)
	_new_stage()
	_set_paused(true)
	_trace("seated " + ", ".join(players.map(func(p): return "bot" if p.bot else "%s (seat %d)" % [p.name, p.seat])))
	GameNight.notify_ready(session_id)


## Values from the party: the gearbox applies at once, the rest from
## the next stage.
func _on_setting(key: String, value: Variant) -> void:
	for s in SETTINGS:
		if s.key != key:
			continue
		match s.kind:
			"number": settings[key] = clampi(int(value), s.min, s.max)
			"toggle": settings[key] = bool(value)
			"choice":
				if str(value) in s.options:
					settings[key] = str(value)
		_trace("setting %s = %s" % [key, settings[key]])
		if key == "render_scale":
			_apply_render_scale()
		if key == "gearbox":
			for p in players:
				if p.car:
					p.car.manual = settings.gearbox == "manual"


## A profile picked up in the lobby: the same driver with a new name. The
## stage and the car keep going.
func _on_players_updated(profiles: Array) -> void:
	for profile in profiles:
		var id := str(profile.get("id", ""))
		for p in players:
			if id != "" and str(p.profile.get("id", "")) == id:
				p.profile = profile
				if profile.has("name"):
					p.name = str(profile.name)
				_trace("renamed %s (seat %d)" % [p.name, p.seat])
	# Someone moved on the couch: the views slide over, the stage goes on.
	_arrange_views()


## The 3D of each view drawn at a lower resolution and brought up with FSR 2
## (which also does the anti-aliasing), the HUD stays sharp. "auto" keeps
## about 2 megapixels of 3D per view: two native 4K views were 11 ms of GPU
## on their own, over the whole 120 fps budget.
func _apply_render_scale() -> void:
	for v in find_children("*", "SubViewport", true, false):
		if not v.has_meta("view"):
			continue
		var vp := v as SubViewport
		var scale := 1.0
		match str(settings.render_scale):
			"100%": scale = 1.0
			"75%": scale = 0.75
			"67%": scale = 0.67
			"50%": scale = 0.5
			_: scale = clampf(sqrt(2.1e6 / maxf(float(vp.size.x * vp.size.y), 1.0)), 0.5, 1.0)
		if scale < 0.98:
			vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2
			vp.scaling_3d_scale = scale
			vp.use_taa = false # FSR 2 brings its own
		else:
			vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
			vp.scaling_3d_scale = 1.0
			vp.use_taa = true


func _on_disposed(_s: String) -> void:
	session = ""
	_set_paused(true)
	_trace("disposed")


func _set_paused(p: bool) -> void:
	host_paused = p
	get_tree().paused = false
	_trace("paused" if p else "running")


## Players with a view: humans and seated bots. AI rivals are added per stage.
func _seat(roster: Array) -> void:
	for p in players:
		if p.view:
			p.view.queue_free()
	players.clear()
	for i in roster.size():
		var r: Dictionary = roster[i]
		players.append({
			"name": r.get("name", NAMES[i % NAMES.size()]), "color": r.get("color", COLORS[i % COLORS.size()]),
			"bot": r.bot, "seat": r.seat, "pad": r.pad, "profile": r.get("profile", {}), "rival": false,
			"car": null, "ai": null, "view": null, "hud": null, "camera": null, "cam_mode": 0,
			"time": 0.0, "finished": false, "penalty": 0.0, "hint": -1, "along": 0.0,
			"held": {}, "pressed": {}, "ghost": 0.0, "off_road": 0.0,
			"drove": false, "held_before_a": false,
		})
	_layout_views()


func _layout_views() -> void:
	for c in views_root.get_children():
		c.queue_free()
	var count := players.size()
	var size := get_viewport().get_visible_rect().size
	Look.views(sun, count)
	for i in count:
		var p: Dictionary = players[i]
		var rect := _view_rect(i, count, size)
		var view_origin := Node2D.new()
		view_origin.position = rect.position
		var container := SubViewportContainer.new()
		container.size = rect.size
		container.stretch = true
		container.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var vp := SubViewport.new()
		vp.size = Vector2i(rect.size)
		# TAA instead of MSAA: it also settles the dithered tree fades, the
		# needle cards and the gravel sparkle that made the picture look
		# noisy, and costs less than MSAA.
		vp.msaa_3d = Viewport.MSAA_DISABLED
		vp.use_taa = true
		vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
		vp.set_meta("view", true)
		vp.audio_listener_enable_3d = i == 0
		vp.positional_shadow_atlas_size = 0
		container.add_child(vp)
		if perf:
			perf.watch(vp)
		var cam := ChaseCamera.new()
		vp.add_child(cam)
		view_origin.add_child(container)
		views_root.add_child(view_origin)
		var hud := Hud.new()
		hud.main = self
		hud.index = i
		hud.position = rect.position
		hud.size = rect.size
		hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
		views_root.add_child(hud)
		p.view = container
		p.camera = cam
		p.hud = hud
	_arrange_views()
	_apply_render_scale()


## Views go in couch order: the leftmost player on the couch (picked in the
## lobby's Start menu) drives in the top or top-left view.
func _arrange_views() -> void:
	var viewed := players.filter(func(p): return is_instance_valid(p.view))
	var order := viewed.duplicate()
	order.sort_custom(func(a, b): return _couch_key(a) < _couch_key(b))
	var logical_size := get_viewport().get_visible_rect().size
	var pixel_scale := get_viewport().get_stretch_transform().get_scale()
	if not pixel_scale.is_finite() or pixel_scale.x <= 0.0 or pixel_scale.y <= 0.0:
		return
	for p in viewed:
		var rect := _view_rect(order.find(p), viewed.size(), logical_size)
		# SubViewportContainer uses its local size for the render target. Undo
		# canvas stretching on its origin so each 3D texel is a screen pixel,
		# while HUD siblings keep the normal logical UI scale. Round boundaries
		# before sizing to avoid fractional texels on odd window dimensions.
		# A Node2D origin avoids Control position snapping and float offset
		# cancellation that can truncate an otherwise integer viewport size.
		var first_pixel := (rect.position * pixel_scale).round()
		var last_pixel := (rect.end * pixel_scale).round()
		var view_origin := p.view.get_parent() as Node2D
		view_origin.position = first_pixel / pixel_scale
		view_origin.scale = Vector2.ONE / pixel_scale
		p.view.size = (last_pixel - first_pixel).max(Vector2(2, 2))
		p.hud.position = rect.position
		p.hud.size = rect.size
	_trace("views " + ", ".join(order.map(func(p): return "bot" if p.bot else p.name)))


## Couch place first (older hosts and bots have none), then seat.
func _couch_key(p: Dictionary) -> int:
	var couch: Variant = p.profile.get("couch")
	return (int(couch) if couch != null else 99) * 100 + int(p.seat) + 1


func _view_rect(i: int, count: int, size: Vector2) -> Rect2:
	var gap := 4.0
	if count <= 1:
		return Rect2(Vector2.ZERO, size)
	if count == 2:
		var h := (size.y - gap) / 2.0
		return Rect2(Vector2(0, i * (h + gap)), Vector2(size.x, h))
	var w := (size.x - gap) / 2.0
	var hh := (size.y - gap) / 2.0
	return Rect2(Vector2((i % 2) * (w + gap), (i / 2) * (hh + gap)), Vector2(w, hh))


## --strip: switch parts of the picture off to see what they cost.
func _strip() -> void:
	for n in stage_root.find_children("*", "GeometryInstance3D", true, false):
		if str(n.get_meta("strip", "")) in strip:
			n.visible = false
	if "shadows" in strip:
		sun.shadow_enabled = false
	if "ssao" in strip:
		environment.ssao_enabled = false
	if "glow" in strip:
		environment.glow_enabled = false
	if "fog" in strip:
		environment.fog_enabled = false
		environment.volumetric_fog_enabled = false
	if "msaa" in strip:
		for v in find_children("*", "SubViewport", true, false):
			(v as SubViewport).msaa_3d = Viewport.MSAA_DISABLED


## A new stage takes seconds to build, all on this frame: put a cover over
## the screen first so it doesn't look frozen.
func _new_stage_soon() -> void:
	if building:
		return
	building = true
	overlay.queue_redraw()
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
	_new_stage()
	building = false
	overlay.queue_redraw()


func _new_stage() -> void:
	round_number += 1
	stats.stages += 1
	# Drop the old stage and rivals.
	if stage_root:
		stage_root.queue_free()
	# Every car goes, the rivals' too: a rival's car left behind sits in the
	# world where the next stage starts.
	for p in players:
		if p.car:
			p.car.queue_free()
			p.car = null
	players = players.filter(func(p): return not p.rival)
	weather = settings.weather
	if weather == "random":
		weather = Look.WEATHERS[randi() % Look.WEATHERS.size()]
	if weather_override != "":
		weather = weather_override
	Look.weather(environment, sun, weather)
	var t0 := Time.get_ticks_msec()
	stage = Stage.new()
	var km: float = km_override if km_override > 0.0 else float(settings.stage_km)
	stage.generate(km * 1000.0 + Stage.RUNOUT)
	stage_root = Node3D.new()
	stage_root.name = "Stage"
	world.add_child(stage_root)
	var builder := StageBuilder.new(stage)
	var t1 := Time.get_ticks_msec()
	tracks = TrackMap.new(stage.length)
	builder.road_material.set_shader_parameter("track_map", tracks.texture)
	var chunks := builder.build(stage_root)
	Forest.build(stage_root, builder.tree_spots, players.filter(func(p): return p.view != null).size())
	Canopy.build(stage_root, builder.tree_spots)
	GrassField.build(stage_root, builder.ground_map, builder.ground_origin, settings.vegetation, players.filter(func(p): return p.view != null).size())
	GroundCover.build(stage_root, builder.grass_spots, builder.fern_spots, builder.rock_spots, builder.stump_spots)
	Props.start_finish(stage_root, stage)
	if not strip.is_empty():
		_strip()
	_trace("built in %d ms (layout %d ms)" % [Time.get_ticks_msec() - t0, t1 - t0])
	_trace("weather " + weather)
	var starts: Array[String] = []
	for k in range(1, stage.ledges.size()):
		if stage.ledges[k] != 0.0 and stage.ledges[k - 1] == 0.0:
			starts.append("%d m" % (k * Stage.STEP))
	_trace("ledges at " + ", ".join(starts))
	_trace("streams at " + ", ".join(stage.rivers.map(func(r): return "%d m %s" % [r.cross * Stage.STEP, "ford" if r.ford else "bridge"])))
	_trace("stage %d: %.0f m, %d chunks, %d trees, %d tufts, %d notes" % [round_number, stage.length, chunks, builder.tree_spots.size(), builder.grass_spots.size(), stage.notes.size()])
	# AI rivals: cars without a view. Left at the default, a party of two or
	# more races each other and the solo driver gets one rival.
	var rivals: int = settings.rivals
	if rivals == 1 and players.filter(func(p): return not p.bot).size() >= 2:
		rivals = 0
	for r in rivals:
		var i := players.size()
		players.append({
			"name": "AI %d" % (r + 1), "color": COLORS[(i + 3) % COLORS.size()], "bot": true, "seat": -1, "pad": -1,
			"profile": {}, "rival": true, "car": null, "ai": null, "view": null, "hud": null, "camera": null,
			"cam_mode": 0, "time": 0.0, "finished": false, "penalty": 0.0, "hint": -1, "along": 0.0,
			"held": {}, "pressed": {}, "ghost": 0.0, "off_road": 0.0,
			"drove": false, "held_before_a": false,
		})
	for i in players.size():
		var p: Dictionary = players[i]
		var car := Car.new()
		car.setup(CarSpec.GRID[i % CarSpec.GRID.size()])
		car.name = "Car%d" % i
		car.surface_at = stage.surface_near
		if not stage.rivers.is_empty():
			car.water_at = stage.water_level
		car.manual = settings.gearbox == "manual"
		for shape in CarModel.collision(car):
			car.add_child(shape)
		# Ghosts: cars only collide with the world unless contact is on.
		car.collision_layer = 2
		car.collision_mask = 1 | (2 if settings.contact else 0)
		CarModel.build(car, p.color)
		world.add_child(car)
		DoorSticker.attach(car, p, i)
		CarLights.attach(car)
		Backfire.attach(car)
		if dirt_override >= 0.0:
			car.dirt = dirt_override
			for g in car.dirty:
				g.set_instance_shader_parameter("dirt", dirt_override)
		stage_root.add_child(WheelFx.new(car))
		p.car = car
		p.ai = RallyAI.new(stage, randf_range(0.86, 0.97) if p.rival else 0.95) if p.bot else null
		p.time = 0.0
		p.finished = false
		p.penalty = 0.0
		p.hint = -1
		p.along = start_at
		p.off_road = 0.0
		_place(p, start_at, i)
		if p.camera:
			p.camera.car = car
			p.camera.mode = _cam_mode(p)
			p.camera.snap()
	if perf:
		perf.car_count = players.size()
	phase = "countdown"
	clock = -COUNTDOWN
	first_finish = -1.0
	results = 0.0


func _cam_mode(p: Dictionary) -> int:
	if cam_override != "":
		return ["chase", "bonnet", "far", "side", "top"].find(cam_override)
	return p.cam_mode


## A spot on the road at or before `along` with no water within a car's
## length or two, so a reset never drops a car into a ford.
func _dry_along(along: float) -> float:
	var a := along
	while a > 4.0:
		var wet := false
		for d in [-10.0, -5.0, 0.0, 5.0, 10.0]:
			var q := stage.point_at(clampf(a + d, 0.0, stage.length))
			if stage.water_level(q.x, q.z) > stage.height(q.x, q.z) - 0.3:
				wet = true
				break
		if not wet:
			return a
		a -= 4.0
	return a


## Grid: two abreast when contact is on, otherwise everyone on the line.
func _place(p: Dictionary, along: float, slot: int) -> void:
	var a := clampf(along, 4.0, stage.finish - 12.0)
	var offset := 0.0
	if settings.contact:
		a -= (slot / 2) * 8.0
		offset = -1.3 if slot % 2 == 0 else 1.3
	var pos := stage.point_at(a)
	var dir := stage.dir_at(a)
	var right := Vector3(-dir.z, 0.0, dir.x)
	pos += right * offset
	pos.y = stage.height(pos.x, pos.z) + 0.36
	var xf := Transform3D(Basis.looking_at(dir, Vector3.UP), pos)
	p.car.teleport(xf)
	p.hint = -1
	p.along = a


func _physics_process(delta: float) -> void:
	frame += 1
	if sim_frames > 0 and frame >= sim_frames:
		_finish_sim()
		return
	if shot != "":
		# Software rendering is slow, so the 3D views stay switched off until
		# the last few frames (particles and the camera need those to settle).
		var fast := frame < shot_frames - shot_render * 4
		for v in find_children("*", "SubViewport", true, false):
			if not v.has_meta("bake"):
				(v as SubViewport).render_target_update_mode = SubViewport.UPDATE_DISABLED if fast else SubViewport.UPDATE_ALWAYS
		if shot_menu and frame == shot_frames - 3:
			menu_owner = 0
		if frame == shot_frames:
			_save_shot()
	if host_paused or players.is_empty() or stage == null:
		PhysicsServer3D.set_active(not host_paused)
		return
	for p in players:
		_read(p)
	# The Start menu and a host pause stop the whole world, cars mid-air included.
	var open := _menu()
	PhysicsServer3D.set_active(not open)
	if open:
		return
	clock += delta
	if phase == "results":
		results -= delta
		if results <= 0.0:
			_new_stage_soon()
			return
	for p in players:
		_drive(p, delta)
	tracks.upload()
	if phase == "countdown" and clock >= 0.0:
		phase = "racing"
		_trace("stage go")
	if phase == "racing":
		var all_done := true
		for p in players:
			if not p.finished:
				all_done = false
		if all_done or (first_finish >= 0.0 and clock - first_finish > FINISH_GRACE):
			_end_stage()
	overlay.queue_redraw()


func _drive(p: Dictionary, delta: float) -> void:
	var car: Car = p.car
	if car == null:
		return
	if not p.bot:
		_rumble(p, car, delta)
	var loc := stage.locate(car.global_position, p.hint)
	if loc.index >= 0:
		p.hint = loc.index
		p.along = loc.along
	car.hold = phase == "countdown"
	if p.ghost > 0.0:
		p.ghost -= delta
		if p.ghost <= 0.0 and _near_other(p, 6.0):
			p.ghost = 0.3
		elif p.ghost <= 0.0:
			car.collision_layer = 2
			car.collision_mask = 1 | 2
	if phase == "countdown":
		car.throttle = p.held.get("throttle", 0.0) if not p.bot else (0.6 if clock > -0.8 else 0.0)
		return
	if p.finished:
		car.throttle = 0.0
		car.brake = 0.6
		car.steer_input = 0.0
		return
	if p.bot:
		p.ai.drive(car, delta)
	else:
		_human(p, car)
	stats.airtime = maxf(stats.airtime, car.stats.air_time)
	for w in car.wheels:
		if w.slide > 0.3:
			stats.slides += delta * 0.25
	if loc.index >= 0:
		_mark(car, loc)
	# Recovery: stuck, upside down, or lost in the woods.
	var lost: bool = loc.index < 0 or absf(loc.offset) > stage.width_at(p.along) + 22.0
	var upside: bool = car.global_basis.y.y < 0.2
	var stuck: bool = car.linear_velocity.length() < 1.0 and (car.throttle > 0.5 or car.brake > 0.5)
	var off_track: bool = lost or upside or stuck or absf(loc.offset) > stage.width_at(p.along) + 2.5
	p.off_track = p.get("off_track", 0.0) + delta if off_track else 0.0
	p.off_road = p.off_road + delta if (lost or upside or stuck or (p.bot and p.ai.stuck > 3.0)) else 0.0
	if p.off_road > (2.5 if upside or lost else 5.0) or p.get("recover", false):
		_trace("lost %s at %.0f m: lost %s upside %s stuck %s offset %.1f" % [p.name, p.along, lost, upside, stuck, loc.offset])
		_recover(p)
	if p.along >= stage.finish:
		p.finished = true
		p.time = clock + p.penalty
		stats.finishes += 1
		if first_finish < 0.0:
			first_finish = clock
		_trace("finish %s %.2f" % [p.name, p.time])


## Each wheel on the ground marks the gravel under it.
func _mark(car: Car, loc: Dictionary) -> void:
	var dir := stage.dir_at(loc.along)
	var right: Vector3 = loc.right
	var w_road := stage.width_at(loc.along)
	for w in car.wheels:
		if not w.contact:
			tracks.stamp(w, 0.0, 9.0, 0.0, 0.0)
			continue
		var rel: Vector3 = w.point - car.global_position
		var along: float = loc.along + rel.x * dir.x + rel.z * dir.z
		var u: float = TrackMap.across(loc.offset + rel.x * right.x + rel.z * right.z, w_road)
		tracks.stamp(w, along, u, clampf(w.load / 3500.0, 0.2, 1.0), w.slide)


func _near_other(p: Dictionary, r: float) -> bool:
	for o in players:
		if o != p and o.car and o.car.global_position.distance_to(p.car.global_position) < r:
			return true
	return false


func _recover(p: Dictionary) -> void:
	p.recover = false
	p.off_track = 0.0
	p.off_road = 0.0
	p.penalty += RECOVER_PENALTY
	stats.recoveries += 1
	_place(p, _dry_along(p.along - 6.0), 0)
	if settings.contact:
		p.ghost = GHOST_SECONDS
		p.car.collision_layer = 4
		p.car.collision_mask = 1
	if p.ai:
		p.ai.stuck = 0.0
		p.ai.hint = -1
	if p.camera:
		p.camera.snap()
	_trace("recover " + p.name)


func _human(p: Dictionary, car: Car) -> void:
	var h: Dictionary = p.held
	car.throttle = h.throttle
	car.brake = h.brake
	car.steer_input = h.steer
	car.handbrake = 1.0 if h.a else 0.0
	var up: bool = p.pressed.get("rb", false)
	var down: bool = p.pressed.get("lb", false)
	# Shifting is only for the manual gearbox, an explicit choice in the menu.
	if (up or down) and car.manual:
		car.request_shift(1 if up else -1)
		_trace("shift %s %s" % [p.name, "up" if up else "down"])
	if h.a and not p.held_before_a:
		_trace("handbrake " + p.name)
	p.held_before_a = h.a
	if car.speed > 3.0 and not p.drove:
		p.drove = true
		_trace("drove " + p.name)
	# X puts the car back on the road (5 s penalty), Y changes the camera.
	if p.pressed.get("x", false) and phase == "racing":
		p.recover = true
	if p.pressed.get("y", false):
		p.cam_mode = (p.cam_mode + 1) % 3
		if p.camera:
			p.camera.mode = p.cam_mode


## The pad feels the road and the grip (see Rumble). A local pad is driven
## directly; a GameNight seat once the SDK can pass rumble on to the host.
func _rumble(p: Dictionary, car: Car, delta: float) -> void:
	if not p.has("rumble"):
		p.rumble = Rumble.new()
	var m: Vector2 = p.rumble.feel(car, delta) if phase == "racing" and not p.finished else Vector2.ZERO
	if frame % 4 != 0:
		return
	if p.seat >= 0:
		if GameNight.has_method("rumble"):
			GameNight.call("rumble", p.seat, m.x, m.y, 0.12)
	elif p.pad >= 0:
		if m == Vector2.ZERO:
			Input.stop_joy_vibration(p.pad)
		else:
			Input.start_joy_vibration(p.pad, m.x, m.y, 0.12)


## Reads one player's pad (GameNight seat, joypad or keyboard) into held/pressed.
## Back is never read: GameNight owns it.
func _read(p: Dictionary) -> void:
	var held := {"throttle": 0.0, "brake": 0.0, "steer": 0.0, "a": false, "b": false, "x": false, "y": false,
		"lb": false, "rb": false, "start": false, "up": false, "down": false, "left": false, "right": false}
	if p.bot:
		p.held = held
		p.pressed = {}
		return
	var stick := Vector2.ZERO
	if p.seat >= 0:
		var f := GameNight.frame_for_seat(p.seat, true)
		stick = GameNight.stick(f, 0)
		held.throttle = GameNight.trigger(f, 1)
		held.brake = GameNight.trigger(f, 0)
		var map := {"a": GameNight.BUTTON_A, "b": GameNight.BUTTON_B, "x": GameNight.BUTTON_X, "y": GameNight.BUTTON_Y,
			"lb": GameNight.BUTTON_LB, "rb": GameNight.BUTTON_RB, "start": GameNight.BUTTON_START,
			"up": GameNight.BUTTON_UP, "down": GameNight.BUTTON_DOWN, "left": GameNight.BUTTON_LEFT, "right": GameNight.BUTTON_RIGHT}
		for k in map:
			held[k] = GameNight.button(f, map[k])
	else:
		var pad: int = p.pad
		stick = Vector2(Input.get_joy_axis(pad, JOY_AXIS_LEFT_X), Input.get_joy_axis(pad, JOY_AXIS_LEFT_Y))
		if stick.length() < 0.12:
			stick = Vector2.ZERO
		held.throttle = maxf(Input.get_joy_axis(pad, JOY_AXIS_TRIGGER_RIGHT), 0.0)
		held.brake = maxf(Input.get_joy_axis(pad, JOY_AXIS_TRIGGER_LEFT), 0.0)
		var map := {"a": JOY_BUTTON_A, "b": JOY_BUTTON_B, "x": JOY_BUTTON_X, "y": JOY_BUTTON_Y, "lb": JOY_BUTTON_LEFT_SHOULDER,
			"rb": JOY_BUTTON_RIGHT_SHOULDER, "start": JOY_BUTTON_START, "up": JOY_BUTTON_DPAD_UP, "down": JOY_BUTTON_DPAD_DOWN,
			"left": JOY_BUTTON_DPAD_LEFT, "right": JOY_BUTTON_DPAD_RIGHT}
		for k in map:
			held[k] = Input.is_joy_button_pressed(pad, map[k])
		if pad == 0:
			stick.x += float(Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT)) - float(Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT))
			if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
				held.throttle = 1.0
			if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
				held.brake = 1.0
			held.a = held.a or Input.is_key_pressed(KEY_SPACE)
			held.rb = held.rb or Input.is_key_pressed(KEY_E)
			held.lb = held.lb or Input.is_key_pressed(KEY_Q)
			held.y = held.y or Input.is_key_pressed(KEY_C)
			held.start = held.start or Input.is_key_pressed(KEY_ESCAPE)
			held.x = held.x or Input.is_key_pressed(KEY_R)
	held.steer = clampf(stick.x, -1.0, 1.0)
	# Menu navigation: stick or d-pad, one step per push.
	held.up = held.up or stick.y < -0.6
	held.down = held.down or stick.y > 0.6
	held.left = held.left or stick.x < -0.6
	held.right = held.right or stick.x > 0.6
	var pressed := {}
	for k in held:
		if held[k] is bool:
			pressed[k] = held[k] and not p.held.get(k, false)
	p.held = held
	p.pressed = pressed


## Every GameNight Start menu has the same layout: the game's name, Resume,
## New stage (applies the options), then the settings. No button hints.
const MENU_ACTIONS := ["Resume", "New stage"]


func _menu() -> bool:
	if menu_owner < 0:
		for i in players.size():
			if not players[i].bot and players[i].pressed.get("start", false):
				menu_owner = i
				menu_row = 0
				menu_from = players[i].car.global_position if players[i].car else Vector3.ZERO
				_trace("menu open")
				overlay.queue_redraw()
				return true
		return false
	var p: Dictionary = players[menu_owner]
	overlay.queue_redraw()
	if p.pressed.get("start", false) or p.pressed.get("b", false):
		menu_owner = -1
		_trace("menu closed, car moved %.2f m" % (p.car.global_position.distance_to(menu_from) if p.car else 0.0))
		return true
	if p.pressed.get("up", false) or p.pressed.get("down", false):
		menu_row = posmod(menu_row + (1 if p.pressed.get("down", false) else -1), MENU_ACTIONS.size() + SETTINGS.size())
	if p.pressed.get("a", false) and menu_row < MENU_ACTIONS.size():
		if MENU_ACTIONS[menu_row] == "New stage":
			_new_stage_soon()
		menu_owner = -1
		_trace("menu closed, car moved %.2f m" % (p.car.global_position.distance_to(menu_from) if p.car else 0.0))
		return true
	var step := int(p.pressed.get("right", false) or p.pressed.get("a", false)) - int(p.pressed.get("left", false))
	if step != 0 and menu_row >= MENU_ACTIONS.size():
		var s: Dictionary = SETTINGS[menu_row - MENU_ACTIONS.size()]
		var value: Variant = settings[s.key]
		match s.kind:
			"number": value = int(value) + step
			"toggle": value = not bool(value)
			"choice":
				var opts: Array = s.options
				value = opts[posmod(opts.find(value) + step, opts.size())]
		_on_setting(s.key, value)
		if GameNight.launched_by_daemon:
			GameNight.set_setting(s.key, settings[s.key])
	return true


func _end_stage() -> void:
	phase = "results"
	results = RESULTS_SECONDS
	for p in players:
		if not p.finished:
			p.time = INF
		if p.car:
			stats.shifts += p.car.stats.shifts
	var ranking := players.duplicate()
	ranking.sort_custom(func(x, y): return x.time < y.time)
	_trace("stage %d won by %s" % [round_number, ranking[0].name])
	if session != "":
		GameNight.notify_finished(session)


func standings() -> Array:
	var list := players.duplicate()
	list.sort_custom(func(x, y):
		if x.finished != y.finished:
			return x.finished
		if x.finished:
			return x.time < y.time
		return x.along > y.along)
	return list


static func format_time(t: float) -> String:
	if t == INF:
		return "DNF"
	var m := int(t / 60.0)
	var s := t - m * 60.0
	return "%d:%05.2f" % [m, s]


func _draw_overlay() -> void:
	var font: Font = Look.font()
	var size := overlay.size
	if building:
		overlay.draw_rect(Rect2(Vector2.ZERO, size), Color(0.03, 0.04, 0.04, 0.9))
		overlay.draw_string(Look.title_font(), Vector2(0, size.y / 2 - 10), "Sideways", HORIZONTAL_ALIGNMENT_CENTER, size.x, 72)
		overlay.draw_string(font, Vector2(0, size.y / 2 + 60), "Building the next stage", HORIZONTAL_ALIGNMENT_CENTER, size.x, 36, Color(1, 1, 1, 0.7))
		return
	if phase == "results":
		var list := standings()
		var box := Rect2(size.x / 2 - 380, size.y / 2 - 60 - list.size() * 34, 760, 120 + list.size() * 68)
		overlay.draw_rect(box, Color(0.04, 0.05, 0.05, 0.86))
		var best: float = list[0].time
		for i in list.size():
			var r: Dictionary = list[i]
			var y := box.position.y + 70 + i * 68
			overlay.draw_rect(Rect2(box.position.x + 40, y - 34, 10, 44), r.color)
			if not r.profile.is_empty():
				faces.draw_face(overlay, r.profile, Vector2(box.position.x + 90, y - 12), 22.0)
			overlay.draw_string(font, Vector2(box.position.x + 130, y), r.name, HORIZONTAL_ALIGNMENT_LEFT, 330, 40)
			var t := format_time(r.time) if r.finished else "DNF"
			if i > 0 and r.finished and best != INF:
				t = "+" + format_time(r.time - best)
			overlay.draw_string(font, Vector2(box.position.x + 420, y), t, HORIZONTAL_ALIGNMENT_RIGHT, 300, 40)
	if menu_owner >= 0:
		var rows := MENU_ACTIONS.size() + SETTINGS.size()
		var box := Rect2(size.x / 2 - 652, size.y / 2 - 90 - rows * 32, 760, 170 + rows * 64)
		_draw_controls(Rect2(box.end.x + 24, box.position.y, 520, box.size.y), font)
		overlay.draw_rect(box, Color(0.04, 0.05, 0.05, 0.93))
		overlay.draw_rect(box, players[menu_owner].color, false, 4.0)
		overlay.draw_string(Look.title_font(), Vector2(box.position.x, box.position.y + 84), "Sideways", HORIZONTAL_ALIGNMENT_CENTER, box.size.x, 60)
		for i in rows:
			var y := box.position.y + 160 + i * 64
			var col := Color.WHITE if i == menu_row else Color(1, 1, 1, 0.5)
			if i < MENU_ACTIONS.size():
				overlay.draw_string(font, Vector2(box.position.x, y), MENU_ACTIONS[i], HORIZONTAL_ALIGNMENT_CENTER, box.size.x, 34, col)
				continue
			var s: Dictionary = SETTINGS[i - MENU_ACTIONS.size()]
			var label: String = s.label
			overlay.draw_string(font, Vector2(box.position.x + 50, y), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 30, col)
			var v: Variant = settings[s.key]
			var text := str(v)
			if s.kind == "toggle":
				text = "on" if v else "off"
			overlay.draw_string(font, Vector2(box.position.x + 470, y), "‹ %s ›" % text, HORIZONTAL_ALIGNMENT_RIGHT, 240, 30, col)


## Asked for by players: Start shows what every button does, next to the menu.
const CONTROLS := [["RT", "Throttle"], ["LT", "Brake"], ["Left stick", "Steer"], ["A", "Handbrake"],
	["X", "Back on the road"], ["Y", "Camera"], ["RB / LB", "Gear up / down"], ["Start", "Menu"]]


func _draw_controls(box: Rect2, font: Font) -> void:
	overlay.draw_rect(box, Color(0.04, 0.05, 0.05, 0.93))
	overlay.draw_string(font, Vector2(box.position.x, box.position.y + 74), "Controls", HORIZONTAL_ALIGNMENT_CENTER, box.size.x, 40)
	var y := box.position.y + 140
	for c in CONTROLS:
		var dim: bool = c[0] == "RB / LB" and settings.gearbox != "manual"
		var col := Color(1, 1, 1, 0.35 if dim else 0.9)
		overlay.draw_string(font, Vector2(box.position.x + 40, y), c[0], HORIZONTAL_ALIGNMENT_LEFT, 170, 28, Color(1, 0.82, 0.3, 0.4 if dim else 1.0))
		var what: String = c[1]
		if dim:
			what = "Gears (manual only)"
		elif c[0] == "LT" and settings.gearbox != "manual":
			what += ", hold to reverse"
		overlay.draw_string(font, Vector2(box.position.x + 210, y), what, HORIZONTAL_ALIGNMENT_LEFT, box.size.x - 230, 28, col)
		y += 52


func _save_shot() -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(shot)
	print("shot: ", shot)
	get_tree().quit()


func _finish_sim() -> void:
	set_physics_process(false)
	var state := PackedStringArray()
	for p in players:
		var c: Car = p.car
		state.append("%.3f,%.3f,%.3f,%.2f" % [c.global_position.x, c.global_position.y, c.global_position.z, p.along])
		_trace("sim %s along %.0f / %.0f finished %s" % [p.name, p.along, stage.length, p.finished])
	stats.shifts += players.reduce(func(acc, p): return acc + (p.car.stats.shifts if p.car else 0), 0)
	print("sim: ", stats, " hash ", ";".join(state).sha256_text().left(16))
	var missing := ["stages", "finishes", "shifts", "slides"].filter(func(k): return float(stats[k]) <= 0.0)
	if missing.is_empty():
		print("sim: ok")
		get_tree().quit(0)
	else:
		printerr("sim: never happened: ", missing)
		get_tree().quit(1)


func _trace(line: String) -> void:
	if trace:
		print(line)
