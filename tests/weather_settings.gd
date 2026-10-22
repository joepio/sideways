extends SceneTree
## Real setting-handler, environment and AI-plan regression; no rendered stage.
## godot --headless --path . --script res://tests/weather_settings.gd

const FIXTURE := """
extends "res://main.gd"
var requested_stages := 0
func _ready() -> void:
	_build_scene()
func _new_stage() -> void:
	requested_stages += 1
"""
var _checks := 0
var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


func _run() -> void:
	await process_frame # Register the real GameNight autoload first.
	var script := GDScript.new()
	script.source_code = FIXTURE
	if script.reload() != OK:
		push_error("Cannot compile weather setting fixture")
		quit(1)
		return
	var game: Node = script.new()
	game.process_mode = Node.PROCESS_MODE_DISABLED
	root.add_child(game)
	var environment: Environment = game.get("environment")
	var sun: DirectionalLight3D = game.get("sun")
	for config in [[1, false, Surfaces.ASPHALT], [4, false, Surfaces.MUD], [1, true, Surfaces.ASPHALT]]:
		var roster: Array = []
		for i in int(config[0]):
			roster.append({"bot": true, "seat": i, "pad": -1})
		game.set("strip", PackedStringArray(["ssao"]) if config[1] else PackedStringArray())
		game.call("_seat", roster)
		await process_frame
		await process_frame
		var ssao_before := environment.ssao_enabled
		var shadow_policy := [sun.directional_shadow_mode, sun.directional_shadow_max_distance, sun.directional_shadow_split_1]
		_expect(ssao_before == (int(config[0]) < 3 and not config[1]), "Fixture did not establish the real view/strip SSAO policy")
		game.set("weather_override", "clear")
		game.set("weather", "clear")
		Look.weather(environment, sun, "clear")
		# Synthetic constant-radius road uses actual surface IDs and real AI.
		var stage := Stage.new()
		stage.points.resize(16)
		stage.curvature.resize(16)
		stage.curvature.fill(0.05)
		stage.road_surfaces.resize(16)
		stage.road_surfaces.fill(int(config[2]))
		var dry_plans: Array[PackedFloat32Array] = []
		var driver_states: Array = []
		for p in game.get("players"):
			p.ai = RallyAI.new(stage, 0.95)
			p.ai.hint = 7
			p.ai.stuck = 0.4
			dry_plans.append(p.ai.plan.duplicate())
			driver_states.append([p.ai.hint, p.ai.stuck, p.ai._wobble, p.ai.pace])
		# An unrelated setting must preserve a forced CLI benchmark weather.
		game.call("_on_setting", "gearbox", "automatic")
		_expect(game.get("weather_override") == "clear", "Unrelated input cleared forced CLI weather")
		seed(44109)
		var after_replan := randi()
		seed(44109)
		game.call("_on_setting", "weather", "wet")
		_expect(randi() == after_replan, "Live weather AI replan consumed gameplay RNG")
		for i in dry_plans.size():
			var ai: RallyAI = game.get("players")[i].ai
			_expect(ai.plan.size() == dry_plans[i].size(), "Replan changed the route sample count")
			for j in ai.plan.size():
				_expect(ai.plan[j] < dry_plans[i][j], "Live wet asphalt/mud did not lower the actual AI speed plan")
			_expect([ai.hint, ai.stuck, ai._wobble, ai.pace] == driver_states[i], "Replan reset driver pursuit/recovery state")
		_expect(game.get("weather_override") == "", "Live weather did not supersede the CLI override")
		_expect(game.get("settings").weather == "wet" and game.get("weather") == "wet", "Wet choice did not become the actual current weather")
		_expect(Look.wetness == 1.0 and CarLights.headlight_energy == 0.9, "Wet weather did not update road/particle wetness and lamps")
		_expect(environment.sky.sky_material is ProceduralSkyMaterial, "Wet weather did not replace the clear sky")
		_expect(is_equal_approx(environment.fog_depth_end, 320.0) and is_equal_approx(sun.light_energy, 0.8) and is_equal_approx(sun.shadow_opacity, 0.5), "Wet sky/fog/shadow properties were not applied immediately")
		var wet_asphalt_mu: float = Surfaces.get_surface(Surfaces.ASPHALT).mu
		_expect(wet_asphalt_mu < float(Surfaces.TABLE[Surfaces.ASPHALT].mu), "Live wet weather did not reach the existing surface response")
		_check_view_policy(environment, sun, ssao_before, shadow_policy)
		game.call("_on_setting", "weather", "clear")
		for i in dry_plans.size():
			var ai: RallyAI = game.get("players")[i].ai
			_expect(ai.plan == dry_plans[i], "Dry weather failed to restore the exact original speed plan")
			_expect([ai.hint, ai.stuck, ai._wobble, ai.pace] == driver_states[i], "Dry replan reset driver state")
		_expect(game.get("weather") == "clear" and Look.wetness == 0.0 and CarLights.headlight_energy == 0.0, "Clear choice did not restore dry weather and daylight lamps")
		_expect(environment.sky.sky_material is PanoramaSkyMaterial, "Clear choice did not restore the HDR sky")
		_expect(is_equal_approx(environment.fog_depth_end, 750.0) and is_equal_approx(sun.light_energy, 2.6) and is_equal_approx(sun.shadow_opacity, 1.0), "Clear fog/sun/shadow values were not restored")
		_expect(Surfaces.get_surface(Surfaces.ASPHALT).mu == Surfaces.TABLE[Surfaces.ASPHALT].mu, "Clear weather did not restore dry asphalt response")
		_check_view_policy(environment, sun, ssao_before, shadow_policy)
		# Invalid input must change neither environment nor a forced CLI choice.
		game.set("weather_override", "mist")
		var sky_id := environment.sky.sky_material.get_instance_id()
		game.call("_on_setting", "weather", "invalid-weather")
		_expect(game.get("weather_override") == "mist" and game.get("weather") == "clear", "Invalid choice mutated forced/current weather")
		_expect(environment.sky.sky_material.get_instance_id() == sky_id, "Invalid choice rebuilt the sky")
		# Random explicitly lifts the CLI lock, but does not reroll the current
		# stage or consume its global random stream during menu interaction.
		seed(90741)
		var next_random := randi()
		seed(90741)
		game.call("_on_setting", "weather", "random")
		_expect(randi() == next_random, "Random weather choice consumed gameplay RNG mid-stage")
		_expect(game.get("weather_override") == "" and game.get("settings").weather == "random", "Random did not clear the CLI override/store the deferred choice")
		_expect(game.get("weather") == "clear" and Look.wetness == 0.0 and environment.sky.sky_material.get_instance_id() == sky_id, "Random must keep the current weather until the next stage")
		_check_view_policy(environment, sun, ssao_before, shadow_policy)
		_expect(game.get("requested_stages") == 0 and game.get("round_number") == 0, "Weather selection regenerated the stage")
		stage.free()
	game.free()
	if _failures == 0:
		print("weather settings: %d checks passed; live profiles, CLI override, deferred random, grip replanning and preserved view policy" % _checks)
	quit(1 if _failures else 0)


func _check_view_policy(environment: Environment, sun: DirectionalLight3D, ssao: bool, shadow_policy: Array) -> void:
	_expect(environment.ssao_enabled == ssao, "Weather overrode split-screen/--strip SSAO")
	_expect([sun.directional_shadow_mode, sun.directional_shadow_max_distance, sun.directional_shadow_split_1] == shadow_policy, "Weather changed the split-screen shadow policy")
