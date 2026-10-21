class_name WheelFx
extends Node3D
## Dust clouds and flying gravel behind one car. Each rear wheel has a dust
## emitter and a stone emitter (GPU particles in world space), moved to the
## contact patch every tick; how much they emit follows speed, slip and the
## surface under the tyre.

var car: Car
var _dust: Array[GPUParticles3D] = []
var _stones: Array[GPUParticles3D] = []
var _spray: Array[GPUParticles3D] = []

static var _dust_pass: QuadMesh
static var _stone_pass: Mesh


func _init(c: Car) -> void:
	car = c
	name = "WheelFx"
	if _dust_pass == null:
		_build_passes()
	for i in 2:
		_dust.append(_dust_emitter())
		_stones.append(_stone_emitter())
		_spray.append(_spray_emitter())


func _physics_process(_delta: float) -> void:
	if not is_instance_valid(car):
		queue_free()
		return
	var v := car.linear_velocity.length()
	# Moist ground binds the fine dust; stones and ford spray keep their
	# own rates. Square the dry fraction so damp stages lose the dense haze.
	var dry := 1.0 - clampf(Look.wetness, 0.0, 1.0)
	var dust_scale := dry * dry
	for i in 2:
		var w: Car.Wheel = car.wheels[2 + i]
		var dust := _dust[i]
		var stones := _stones[i]
		var spray := _spray[i]
		if not w.contact:
			dust.amount_ratio = 0.0
			stones.amount_ratio = 0.0
			spray.amount_ratio = 0.0
			continue
		var xf := Transform3D(car.global_basis, w.point + Vector3.UP * 0.05)
		dust.global_transform = xf
		stones.global_transform = xf
		spray.global_transform = xf
		if w.surface == Surfaces.WATER:
			dust.amount_ratio = 0.0
			stones.amount_ratio = 0.0
			spray.amount_ratio = clampf(v / 12.0, 0.0, 1.0)
			continue
		spray.amount_ratio = 0.0
		# Wheelspin and sliding throw the most; plain rolling at speed still
		# leaves a trail of dust on dry gravel.
		var spin := clampf(absf(w.omega * w.radius - w.vx) / 8.0, 0.0, 1.0)
		var roll := clampf((v - 4.0) / 24.0, 0.0, 1.0)
		var loose := 1.0
		var grass := false
		match w.surface:
			Surfaces.LOOSE:
				loose = 1.3
			Surfaces.GRASS:
				loose = 0.35
				grass = true
			Surfaces.DIRT:
				loose = 0.7
		dust.amount_ratio = dust_scale * clampf(loose * (roll * 0.8 + w.slide * 0.6 + spin * 0.5), 0.0, 1.0)
		stones.amount_ratio = 0.0 if grass else clampf(loose * (w.slide * 0.8 + spin * 0.9 + roll * 0.15), 0.0, 1.0)


func _dust_emitter() -> GPUParticles3D:
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(0.15, 0.05, 0.2)
	pm.direction = Vector3(0.0, 0.45, 1.0) # behind and up, in car space
	pm.spread = 35.0
	pm.initial_velocity_min = 1.0
	pm.initial_velocity_max = 3.5
	pm.inherit_velocity_ratio = 0.15
	pm.gravity = Vector3(0.0, 0.15, 0.0) # warm dust drifts up a little
	pm.damping_min = 1.2
	pm.damping_max = 2.0
	pm.angle_min = -180.0
	pm.angle_max = 180.0
	pm.angular_velocity_min = -20.0
	pm.angular_velocity_max = 20.0
	pm.scale_min = 0.8
	pm.scale_max = 1.4
	var grow := Curve.new()
	grow.max_value = 4.0 # the default range of 0..1 would clip the growth
	grow.add_point(Vector2(0.0, 0.7))
	grow.add_point(Vector2(0.3, 2.0))
	grow.add_point(Vector2(1.0, 3.8))
	var ct := CurveTexture.new()
	ct.curve = grow
	pm.scale_curve = ct
	var ramp := Gradient.new()
	# Damp forest dust: brown-grey and thin, not a bright white cloud.
	ramp.set_color(0, Color(0.42, 0.38, 0.32, 0.0))
	ramp.set_color(1, Color(0.46, 0.42, 0.36, 0.0))
	ramp.add_point(0.06, Color(0.4, 0.36, 0.3, 0.42))
	ramp.add_point(0.5, Color(0.44, 0.4, 0.34, 0.22))
	var gt := GradientTexture1D.new()
	gt.gradient = ramp
	pm.color_ramp = gt
	return _emitter(pm, _dust_pass, 140, 3.2)


func _stone_emitter() -> GPUParticles3D:
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(0.1, 0.02, 0.1)
	pm.direction = Vector3(0.0, 0.6, 1.0)
	pm.spread = 28.0
	pm.initial_velocity_min = 3.0
	pm.initial_velocity_max = 8.0
	pm.inherit_velocity_ratio = 0.3
	pm.gravity = Vector3(0.0, -9.8, 0.0)
	pm.angle_min = -180.0
	pm.angle_max = 180.0
	pm.angular_velocity_min = -400.0
	pm.angular_velocity_max = 400.0
	pm.scale_min = 0.5
	pm.scale_max = 1.6
	return _emitter(pm, _stone_pass, 48, 0.75)


func _spray_emitter() -> GPUParticles3D:
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(0.2, 0.05, 0.2)
	pm.direction = Vector3(0.0, 1.0, 0.7)
	pm.spread = 40.0
	pm.initial_velocity_min = 2.5
	pm.initial_velocity_max = 6.5
	pm.inherit_velocity_ratio = 0.4
	pm.gravity = Vector3(0.0, -9.8, 0.0)
	pm.damping_min = 0.5
	pm.damping_max = 1.0
	pm.scale_min = 0.5
	pm.scale_max = 1.2
	var ramp := Gradient.new()
	ramp.set_color(0, Color(0.9, 0.92, 0.9, 0.7))
	ramp.set_color(1, Color(0.85, 0.88, 0.86, 0.0))
	var gt := GradientTexture1D.new()
	gt.gradient = ramp
	pm.color_ramp = gt
	var quad := QuadMesh.new()
	quad.size = Vector2(0.7, 0.7)
	quad.material = _dust_pass.material
	return _emitter(pm, quad, 120, 0.9)


func _emitter(pm: ParticleProcessMaterial, pass_mesh: Mesh, amount: int, life: float) -> GPUParticles3D:
	var g := GPUParticles3D.new()
	g.process_material = pm
	g.draw_pass_1 = pass_mesh
	g.amount = amount
	g.lifetime = life
	g.local_coords = false
	g.amount_ratio = 0.0
	g.emitting = true
	g.visibility_aabb = AABB(Vector3(-30, -10, -30), Vector3(60, 30, 60))
	g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(g)
	return g


static func _build_passes() -> void:
	# A soft, lumpy puff, drawn lit per vertex so the sun reaches it.
	var n := 64
	var img := Image.create_empty(n, n, false, Image.FORMAT_RGBA8)
	var noise := FastNoiseLite.new()
	noise.frequency = 0.09
	for y in n:
		for x in n:
			var d := Vector2(x - n / 2.0 + 0.5, y - n / 2.0 + 0.5).length() / (n / 2.0)
			var a := clampf(1.0 - d, 0.0, 1.0)
			a = a * a * (0.55 + 0.45 * (noise.get_noise_2d(x, y) * 0.5 + 0.5))
			img.set_pixel(x, y, Color(1, 1, 1, a))
	var dm := StandardMaterial3D.new()
	dm.albedo_texture = ImageTexture.create_from_image(img)
	dm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	dm.vertex_color_use_as_albedo = true
	dm.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
	# Shadows sampled at four corners flipped whole puffs between lit and
	# dark as they drifted over a shadow edge: the smoke flickered.
	dm.disable_receive_shadows = true
	dm.proximity_fade_enabled = true
	dm.proximity_fade_distance = 0.8
	dm.cull_mode = BaseMaterial3D.CULL_DISABLED
	dm.roughness = 1.0
	_dust_pass = QuadMesh.new()
	_dust_pass.size = Vector2(1.7, 1.7)
	_dust_pass.material = dm
	var sm := StandardMaterial3D.new()
	sm.albedo_color = Color(0.36, 0.33, 0.3)
	sm.roughness = 0.9
	var box := BoxMesh.new()
	box.size = Vector3(0.035, 0.025, 0.03)
	box.material = sm
	_stone_pass = box
