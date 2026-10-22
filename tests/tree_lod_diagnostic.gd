extends SceneTree
## Narrow visual diagnosis, not a performance benchmark or automatic visual PASS.
## Modes lod/mid: same camera rail across the real 70m mesh/impostor transition.
## Modes albedo-mid/albedo-far: one same-camera unlit colour/coverage pair at70m.
const OUTPUT := Vector2i(1920, 1080)
const WARMUP := 32
const STEPS := 192
const SPARSE := [0, 24, 48, 72, 120, 144, 168, 191]
var vp: SubViewport
var camera: Camera3D
var output := ""
var mode := ""
var records: Array[Dictionary] = []
var held_shaders: Array[Shader] = []

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		_fail("Tree LOD diagnosis requires real rendering")
		return
	if Engine.physics_ticks_per_second != 120 or Car.SUBSTEPS != 4 or Engine.time_scale != 1.0:
		_fail("Diagnostic requires the current120Hz/4-substep basis at normal time scale")
		return
	var args := OS.get_cmdline_user_args()
	if args.size() != 4 or args[0] != "--mode" or args[2] != "--out":
		_fail("Usage: --mode lod|mid|albedo-mid|albedo-far --out EMPTY_DIRECTORY")
		return
	mode = args[1]
	output = args[3]
	if not mode in ["lod", "mid", "albedo-mid", "albedo-far"] or output.is_empty():
		_fail("Invalid mode/output")
		return
	if DirAccess.dir_exists_absolute(output) and (not DirAccess.get_files_at(output).is_empty() or not DirAccess.get_directories_at(output).is_empty()):
		_fail("Output directory must be empty")
		return
	if DirAccess.make_dir_recursive_absolute(output) != OK:
		_fail("Cannot create output directory")
		return
	vp = SubViewport.new()
	vp.size = OUTPUT
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = 1.0
	vp.use_taa = true
	root.add_child(vp)
	var world := Node3D.new()
	vp.add_child(world)
	var environment := WorldEnvironment.new()
	environment.environment = Look.environment()
	var sun := Look.sun()
	Look.weather(environment.environment, sun, "clear")
	# Remove real caster/fog/SSAO changes as confounds in this visible-LOD test.
	# Both variants use exactly these same diagnostic settings.
	sun.shadow_enabled = false
	environment.environment.fog_enabled = false
	environment.environment.ssao_enabled = false
	environment.environment.glow_enabled = false
	world.add_child(environment)
	world.add_child(sun)
	var forest := Node3D.new()
	world.add_child(forest)
	var spots: Array[Transform3D] = [Transform3D.IDENTITY]
	Forest.build(forest, spots, 1) # The actual grouping selects authored variant b.
	var forced := "far" if mode == "albedo-far" else "mid"
	var kept := 0
	for child in forest.get_children():
		var node := child as MultiMeshInstance3D
		if node.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY:
			node.visible = false
			continue
		var material := node.multimesh.mesh.surface_get_material(0) as ShaderMaterial
		var far := material.shader.resource_path == "res://src/shaders/impostor.gdshader"
		var mid := not far and node.visibility_range_end > Forest.NEAR_END + Forest.FADE + Forest.NEAR_BLOCK * 0.75
		if mode != "lod":
			node.visible = far if forced == "far" else mid
			if not node.visible:
				continue
			node.visibility_range_begin = 0.0
			node.visibility_range_end = 0.0
		kept += 1
		for surface in node.multimesh.mesh.get_surface_count():
			var mat := node.multimesh.mesh.surface_get_material(surface) as ShaderMaterial
			if mat.shader.resource_path == "res://src/shaders/foliage.gdshader":
				mat.set_shader_parameter("sway", 0.0) # No moving geometry in either diagnostic.
			if mode != "lod":
				mat.set_shader_parameter("fade_in_at", -1.0)
				mat.set_shader_parameter("fade_out_at", -1.0)
			if mode.begins_with("albedo-"):
				var unlit := Shader.new()
				unlit.code = mat.shader.code.replace("render_mode ", "render_mode unshaded, ")
				held_shaders.append(unlit)
				mat.shader = unlit
	if kept != (3 if mode == "lod" else 1):
		_fail("Unexpected actual Forest LOD layout")
		return
	camera = Camera3D.new()
	camera.fov = 55.0
	camera.near = 0.1
	camera.far = 500.0
	world.add_child(camera)
	camera.make_current()
	_place(70.0 if mode.begins_with("albedo-") else 88.0)
	for tick in WARMUP:
		await RenderingServer.frame_post_draw
	if mode.begins_with("albedo-"):
		if not _capture(0, 70.0):
			return
	else:
		for step in STEPS:
			var distance_ := 88.0 - 40.0 * float(step) / float(STEPS - 1)
			_place(distance_)
			await RenderingServer.frame_post_draw
			if step in SPARSE or (step >= 80 and step <= 111):
				if not _capture(step, distance_):
					return
	var report := {"status": "captured_pending_visual_review", "mode": mode, "resolution": OUTPUT, "render_scale": 1.0, "taa": vp.use_taa, "physics_hz": Engine.physics_ticks_per_second, "substeps": Car.SUBSTEPS, "warmup_draws": WARMUP, "rail_draws": 0 if mode.begins_with("albedo-") else STEPS, "wind": 0.0, "shadows": false, "fog": false, "ssao": false, "records": records}
	var file := FileAccess.open(output.path_join("trace.json"), FileAccess.WRITE)
	if file == null:
		_fail("Cannot write trace")
		return
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	_finish.call_deferred()

func _finish() -> void:
	vp.queue_free()
	await process_frame
	await process_frame
	held_shaders.clear()
	await RenderingServer.frame_post_draw
	print("TREE_LOD_DIAGNOSTIC_CAPTURED ", records.size(), " ", mode)
	quit()

func _place(distance_: float) -> void:
	# Fixed azimuth halfway between two atlas views also exposes angular dither.
	var angle := deg_to_rad(22.5)
	camera.position = Vector3(sin(angle) * distance_, 3.2, cos(angle) * distance_)
	camera.look_at(Vector3(0.0, 6.5, 0.0), Vector3.UP)

func _capture(step: int, distance_: float) -> bool:
	var image := vp.get_texture().get_image()
	if image == null or image.get_size() != OUTPUT:
		_fail("Actual GPU readback dimensions differ")
		return false
	var name := "frame-%04d.png" % step
	if image.save_png(output.path_join(name)) != OK:
		_fail("Cannot save image")
		return false
	records.append({"step": step, "tree_origin_xz_distance": distance_, "camera": var_to_str(camera.global_transform), "fov": camera.fov, "image": name})
	return true

func _fail(message: String) -> void:
	push_error(message)
	quit(1)
