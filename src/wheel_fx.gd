class_name WheelFx
extends Node3D
## Contact effects on all four tyres. Existing wheel motion drives the effects,
## including free rolling, braking and wheelspin; no drivetrain guess is needed.
## Six emitters share four contact patches and the old total particle budget.
## Particles keep their surface, colour and shape from birth until expiry.

const PARTICLE_SHADER := preload("res://src/shaders/wheel_particles.gdshader")
const DUST_PER_BATCH := 140
const DEBRIS_PER_BATCH := 48
const SPRAY_PER_BATCH := 120

var car: Car
var _dust: Array[GPUParticles3D] = []
var _debris: Array[GPUParticles3D] = []
var _spray: Array[GPUParticles3D] = []
var _materials: Array[ShaderMaterial] = []

static var _dust_pass: QuadMesh
static var _debris_pass: Mesh


func _init(c: Car) -> void:
	car = c
	name = "WheelFx"
	if _dust_pass == null:
		_build_passes()
	for effect in 3:
		var pm := ShaderMaterial.new()
		pm.shader = PARTICLE_SHADER
		pm.set_shader_parameter("effect", effect)
		_materials.append(pm)
	# GPUParticles3D's constructor consumes a global random number. Retain
	# exactly the original six constructions, in the original effect order.
	# Each batch's INDEX % 4 assigns equal capacity to all four wheels.
	for i in 2:
		_dust.append(_emitter(_materials[0], _dust_pass, DUST_PER_BATCH, 3.2))
		_debris.append(_emitter(_materials[1], _debris_pass, DEBRIS_PER_BATCH, 0.75))
		var quad := QuadMesh.new()
		quad.size = Vector2(0.7, 0.7)
		quad.material = _dust_pass.material
		_spray.append(_emitter(_materials[2], quad, SPRAY_PER_BATCH, 0.9))


func _physics_process(_delta: float) -> void:
	if not is_instance_valid(car):
		queue_free()
		return
	var frames: Array[Projection] = []
	var launches := PackedVector4Array()
	var velocities := PackedVector3Array()
	var rates := PackedVector3Array()
	for i in 4:
		var w: Car.Wheel = car.wheels[i]
		# The simulation already projects these axes onto the contact plane.
		# Local +Z is behind this tyre, including steering and banked ground.
		var xf := Transform3D(Basis(w.wr, w.normal, -w.wf), w.point + w.normal * 0.05)
		frames.append(Projection(xf))
		var launch := _launch_velocity(w)
		launches.append(Vector4(launch.x, launch.y, launch.z, w.surface))
		# Use the measured contact velocity, not emitter displacement: a reset
		# must not launch a new particle at teleport speed.
		velocities.append(w.wf * w.vx + w.wr * w.vy)
		rates.append(_rates(w, Look.wetness))
	for pm in _materials:
		pm.set_shader_parameter("wheel_frames", frames)
		pm.set_shader_parameter("wheel_launches", launches)
		pm.set_shader_parameter("wheel_velocities", velocities)
		pm.set_shader_parameter("wheel_rates", rates)
	# Bounds follow the car; the shader writes world-space particle positions.
	for group in [_dust, _debris, _spray]:
		for emitter: GPUParticles3D in group:
			emitter.global_position = car.global_position


## x dust, y solid debris, z spray. Only reads the wheel's physical state.
static func _rates(w: Car.Wheel, wet: float) -> Vector3:
	if not w.contact or w.load <= 0.0:
		return Vector3.ZERO
	var load_scale := clampf(w.load / 3500.0, 0.0, 1.0)
	var speed := Vector2(w.vx, w.vy).length()
	var slip_speed := absf(w.omega * w.radius - w.vx)
	if w.surface == Surfaces.WATER:
		return Vector3(0.0, 0.0, clampf((speed + slip_speed * 0.5) / 12.0, 0.0, 1.0) * load_scale)
	if w.surface == Surfaces.ASPHALT:
		# A wet film makes a little spray; clean tarmac never throws gravel.
		return Vector3(0.0, 0.0, clampf(wet, 0.0, 1.0) * 0.35 * clampf((speed + slip_speed * 0.5) / 12.0, 0.0, 1.0) * load_scale)
	var spin := clampf(slip_speed / 8.0, 0.0, 1.0)
	var roll := clampf((speed - 4.0) / 24.0, 0.0, 1.0)
	var slide := clampf(w.slide, 0.0, 1.0)
	var loose := 1.0
	match w.surface:
		Surfaces.LOOSE: loose = 1.3
		Surfaces.GRASS: loose = 0.35
		Surfaces.DIRT: loose = 0.7
		Surfaces.MUD: loose = 0.8
	# Damp ground binds fine dust, but can still throw clods and clippings.
	var dry := 1.0 - clampf(wet, 0.0, 1.0)
	if w.surface == Surfaces.MUD:
		dry = 0.0 # Bound moist soil throws clods, not a beige powder cloud.
	var dust := dry * dry * clampf(loose * (roll * 0.8 + slide * 0.6 + spin * 0.5), 0.0, 1.0)
	var debris := clampf(loose * (slide * 0.8 + spin * 0.9 + roll * 0.15), 0.0, 1.0)
	return Vector3(dust, debris, 0.0) * load_scale


static func _launch_velocity(w: Car.Wheel) -> Vector3:
	# A driving tyre sweeps material back; a locked tyre pushes it forwards.
	# Reverse and sideways slides follow the same signed contact velocities.
	var slip := clampf(w.omega * w.radius - w.vx, -10.0, 10.0)
	var kick := slip * 0.5 + clampf(w.vx * 0.12, -1.5, 1.5)
	return Vector3(clampf(w.vy * 0.35, -3.0, 3.0), 0.8 + absf(slip) * 0.14, kick)


func _emitter(pm: Material, pass_mesh: Mesh, amount: int, life: float) -> GPUParticles3D:
	var g := GPUParticles3D.new()
	g.process_material = pm
	g.draw_pass_1 = pass_mesh
	g.amount = amount
	g.lifetime = life
	g.local_coords = false
	# Birth probabilities are per wheel in the shared process material.
	g.amount_ratio = 1.0
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
	sm.vertex_color_use_as_albedo = true
	sm.roughness = 0.9
	_debris_pass = _debris_mesh()
	_debris_pass.surface_set_material(0, sm)


## One eight-triangle asymmetric solid, shared by every surface and wheel.
## Birth scaling makes small pebbles/clods or thin tapered grass clippings.
static func _debris_mesh() -> ArrayMesh:
	var points := PackedVector3Array([
		Vector3(0.04, 0.55, -0.03), Vector3(-0.08, -0.45, 0.06),
		Vector3(0.52, 0.04, 0.0), Vector3(0.03, -0.03, 0.48),
		Vector3(-0.48, 0.08, -0.02), Vector3(-0.01, -0.05, -0.52)])
	var faces := PackedInt32Array([0, 2, 3, 0, 3, 4, 0, 4, 5, 0, 5, 2,
		1, 3, 2, 1, 4, 3, 1, 5, 4, 1, 2, 5])
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	for face in range(0, faces.size(), 3):
		var a := points[faces[face]]
		var b := points[faces[face + 1]]
		var c := points[faces[face + 2]]
		# Godot's front faces use clockwise winding.
		var normal := (c - a).cross(b - a).normalized()
		vertices.append_array([a, b, c])
		normals.append_array([normal, normal, normal])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
