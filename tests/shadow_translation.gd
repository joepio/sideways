extends SceneTree
## Real-renderer regression: directional shadows must survive world translation.
## One diagnostic camera exercises both production 1-view and 4-view policies.
const SIZE := Vector2i(512, 512)
const GRID := 64
const MAX_NORMALIZED_DIFFERENCE := 0.25
var output := ""
var world: Node3D
var car: Car
var camera: Camera3D
var sun: DirectionalLight3D
var environment: Environment
var receiver: MeshInstance3D
var failures: Array[String] = []
var results: Array[Dictionary] = []
var captures: Array[Dictionary] = []

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		if args[i] == "--shadow-output": output = args[i + 1].replace("\\", "/")
	if DisplayServer.get_name() == "headless":
		push_error("shadow translation requires the real renderer"); quit(1); return
	if not output.is_empty() and (not DirAccess.dir_exists_absolute(output) or not DirAccess.get_files_at(output).is_empty()):
		push_error("shadow translation output must be a fresh existing directory"); quit(1); return
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	root.scaling_3d_scale = 1.0
	root.use_taa = false
	root.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
	root.msaa_3d = Viewport.MSAA_DISABLED
	_build()
	for policy: int in [1, 4]:
		Look.views(environment, sun, policy, false)
		var distributions: Array[PackedFloat64Array] = []
		var measurements: Array[Dictionary] = []
		for distance: float in [0.0, 2000.0]:
			_place(distance)
			sun.shadow_enabled = true
			var on: Image = await _capture("views%d-at%d-on" % [policy, int(distance)])
			sun.shadow_enabled = false
			var off: Image = await _capture("views%d-at%d-off" % [policy, int(distance)])
			if on == null or off == null:
				_cleanup.call_deferred(); return
			var measure := _measure(on, off, _body_screen_rect().grow(3.0))
			distributions.append(measure.distribution)
			measure.erase("distribution")
			measure["distance"] = distance
			measurements.append(measure)
			_check(float(measure.energy) >= 2.0 and int(measure.strong_pixels) >= 16,
				"visible nonzero ground shadow required, policy%d distance%d: %s" % [policy, int(distance), str(measure)])
		var a: PackedFloat64Array = distributions[0]
		var b: PackedFloat64Array = distributions[1]
		var difference := 0.0
		for i in a.size(): difference += absf(a[i] - b[i])
		var average_energy: float = (float(measurements[0].energy) + float(measurements[1].energy)) * 0.5
		var normalized_difference := difference / maxf(average_energy, 0.000001)
		var ratio: float = float(measurements[1].energy) / maxf(float(measurements[0].energy), 0.000001)
		_check(normalized_difference <= MAX_NORMALIZED_DIFFERENCE,
			"translated shadow footprint changed, policy%d difference=%f" % [policy, normalized_difference])
		_check(ratio >= 0.7 and ratio <= 1.3,
			"translated shadow energy changed, policy%d ratio=%f" % [policy, ratio])
		results.append({"view_policy":policy,"measurements":measurements,"normalized_distribution_difference":normalized_difference,
			"far_near_energy_ratio":ratio,"limit":MAX_NORMALIZED_DIFFERENCE,
			"angular_distance":sun.light_angular_distance,"shadow_distance":sun.directional_shadow_max_distance,
			"splits":sun.directional_shadow_mode,"bias":sun.shadow_bias,"normal_bias":sun.shadow_normal_bias})
		print("SHADOW_TRANSLATION_METRICS ", JSON.stringify(results.back()))
	if not output.is_empty():
		var file := FileAccess.open(output.path_join("shadow-translation.json"), FileAccess.WRITE)
		if file == null: failures.append("Cannot write result JSON")
		else:
			file.store_string(JSON.stringify({"results":results,"captures":captures,"failures":failures,
				"scope":"Static actual Asti, one native512 camera, production1/4-view shadow policy. On/off difference outside projected car bounds. No foliage, route, real4-viewport performance or motion proof."}, "\t"))
			file.close()
	_cleanup.call_deferred()

func _build() -> void:
	seed(4242)
	world = Node3D.new()
	world.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	root.add_child(world)
	environment = Look.environment()
	var env_node := WorldEnvironment.new()
	env_node.environment = environment
	world.add_child(env_node)
	sun = Look.sun()
	world.add_child(sun)
	Look.weather(environment, sun, "clear")
	environment.fog_enabled = false
	environment.glow_enabled = false
	car = Car.new()
	car.setup("asti")
	car.freeze = true
	car.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	world.add_child(car)
	car.set_physics_process(false)
	CarModel.build(car, Color(0.6, 0.2, 0.1))
	for wheel: Car.Wheel in car.wheels:
		wheel.contact = true
		wheel.load = 3000.0
		wheel.compression = 0.1
		wheel.spin = 0.0
		wheel.steer = 0.0
		wheel.fy = 0.0
	car._physics_process(0.0)
	for geometry: GeometryInstance3D in car.dirty: geometry.set_instance_shader_parameter("dirt", 0.0)
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(30.0, 30.0)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.5, 0.5, 0.5)
	material.roughness = 1.0
	mesh.material = material
	receiver = MeshInstance3D.new()
	receiver.mesh = mesh
	# Isolate the car shadow from self-shadow acne on the diagnostic plane.
	receiver.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world.add_child(receiver)
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 10.0
	camera.near = 0.05
	camera.far = 1400.0
	world.add_child(camera)
	camera.current = true

func _place(distance: float) -> void:
	var origin := Vector3(0.0, 0.0, -distance)
	car.position = origin + Vector3.UP * (car.wheels[0].radius - 3000.0 / Car.TYRE_RATE)
	receiver.position = origin
	# Top-down camera leaves the low-angle sunlight's ground projection visible.
	camera.position = origin + Vector3.UP * 10.0
	camera.look_at(origin, Vector3.FORWARD)

func _capture(label: String) -> Image:
	var car_pose := car.global_transform
	var eye := camera.global_transform
	for draw in 24: await RenderingServer.frame_post_draw
	_check(car.global_transform == car_pose and camera.global_transform == eye and car.freeze and not car.is_physics_processing(), "static pose changed")
	var image := root.get_texture().get_image()
	if image == null or image.get_size() != SIZE:
		failures.append("Actual native512 output required; use --resolution512x512")
		return null
	image.convert(Image.FORMAT_RGBA8)
	if not output.is_empty() and image.save_png(output.path_join(label + ".png")) != OK:
		failures.append("Cannot save " + label)
	captures.append({"label":label,"car":str(car_pose),"camera":str(eye),"output":[image.get_width(), image.get_height()],
		"receiver_cast_shadow":receiver.cast_shadow,"shadow_enabled":sun.shadow_enabled,"angular_distance":sun.light_angular_distance,"ssao":environment.ssao_enabled,
		"scale":root.scaling_3d_scale,"mode":root.scaling_3d_mode,"taa":root.use_taa,"screen_aa":root.screen_space_aa})
	return image

func _body_screen_rect() -> Rect2:
	var rect := Rect2()
	var initialized := false
	for node in car.find_children("*", "MeshInstance3D", true, false):
		var geometry := node as MeshInstance3D
		var box := geometry.get_aabb()
		for index in 8:
			var point := camera.unproject_position(geometry.global_transform * box.get_endpoint(index))
			if not initialized:
				rect = Rect2(point, Vector2.ZERO)
				initialized = true
			else: rect = rect.expand(point)
	return rect

func _measure(on: Image, off: Image, excluded: Rect2) -> Dictionary:
	var a := on.get_data()
	var b := off.get_data()
	var distribution := PackedFloat64Array()
	distribution.resize(GRID * GRID)
	var energy := 0.0
	var strong := 0
	for y in SIZE.y:
		for x in SIZE.x:
			if excluded.has_point(Vector2(x + 0.5, y + 0.5)): continue
			var i := (y * SIZE.x + x) * 4
			var delta := (0.2126 * (int(b[i]) - int(a[i])) + 0.7152 * (int(b[i + 1]) - int(a[i + 1])) + 0.0722 * (int(b[i + 2]) - int(a[i + 2]))) / 255.0
			# Ignore one code-value quantization; compare spatial energy in8x8 bins.
			delta = maxf(delta - 1.0 / 255.0, 0.0)
			energy += delta
			if delta > 0.04: strong += 1
			var cell := (y / 8) * GRID + x / 8
			distribution[cell] += delta
	return {"energy":energy,"strong_pixels":strong,"excluded_car_rect":str(excluded),"distribution":distribution}

func _check(condition: bool, message: String) -> void:
	if not condition: failures.append(message)

func _cleanup() -> void:
	car = null
	camera = null
	sun = null
	environment = null
	receiver = null
	if is_instance_valid(world): world.queue_free()
	world = null
	for draw in 3:
		await process_frame
		await RenderingServer.frame_post_draw
	if failures.is_empty() and results.size() == 2:
		print("shadow translation: actual ground-shadow invariance passed for 1/4-view policies")
		quit(0)
	else:
		for failure in failures: push_error("shadow translation: " + failure)
		quit(1)
