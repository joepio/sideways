extends SceneTree
## CPU contract: all four contacts, signed slip, surface routing, fixed total
## capacity, six-constructor RNG footprint, and actual debris mesh buffers.
## Headless does not execute particles. A real-renderer motion check must also
## exercise dust/debris/spray and a surface change while old particles live.

var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_check_rates()
	_check_mesh()
	_check_emitters()
	if failures.is_empty():
		print("wheel fx: four contacts, surface routing, signed slip, budgets, RNG and debris mesh passed")
	else:
		for message in failures:
			push_error(message)
	quit(0 if failures.is_empty() else 1)


func _check_rates() -> void:
	var w := Car.Wheel.new()
	w.contact = true
	w.load = 3500.0
	w.vx = 12.0
	w.omega = w.vx / w.radius
	var roll := WheelFx._rates(w, 0.0)
	_check(roll.x > 0.0 and roll.y > 0.0 and roll.z == 0.0, "a freely rolling contact should disturb gravel")
	w.omega += 8.0 / w.radius
	var spin := WheelFx._rates(w, 0.0)
	_check(spin.x > roll.x and spin.y > roll.y, "actual wheelspin must increase dust and debris")
	_check(WheelFx._launch_velocity(w).z > 0.0, "forward wheelspin must throw material behind the tyre")
	w.omega = 0.0
	_check(WheelFx._launch_velocity(w).z < 0.0, "a locked forward wheel must push material forwards")
	w.vx = -12.0
	w.omega = -20.0 / w.radius
	_check(WheelFx._launch_velocity(w).z < 0.0, "reverse wheelspin must reverse the throw direction")
	w.vy = 8.0
	_check(WheelFx._launch_velocity(w).x > 0.0, "lateral sliding must throw material to that side")
	w.vy = -8.0
	_check(WheelFx._launch_velocity(w).x < 0.0, "lateral throw must preserve its sign")
	for surface in [Surfaces.GRAVEL, Surfaces.LOOSE, Surfaces.GRASS, Surfaces.DIRT]:
		w.surface = surface
		var dry := WheelFx._rates(w, 0.0)
		var wet := WheelFx._rates(w, 1.0)
		_check(dry.y > 0.0 and dry.z == 0.0, "each dry surface must route solid debris, including grass")
		_check(wet.x == 0.0 and wet.y == dry.y, "wetness must suppress fine dust without hiding solid debris")
	w.surface = Surfaces.WATER
	var water := WheelFx._rates(w, 0.0)
	_check(water.x == 0.0 and water.y == 0.0 and water.z > 0.0, "water must route only spray")
	w.surface = Surfaces.ASPHALT
	_check(WheelFx._rates(w, 0.0) == Vector3.ZERO, "clean dry asphalt must not throw gravel/dust")
	var film := WheelFx._rates(w, 1.0)
	_check(film.x == 0.0 and film.y == 0.0 and film.z > 0.0 and film.z < water.z, "wet asphalt should emit only modest film spray")
	w.surface = Surfaces.MUD
	var mud := WheelFx._rates(w, 0.0)
	_check(mud.x == 0.0 and mud.y > 0.0 and mud.z == 0.0, "mud should throw clods without dry powder")
	w.surface = Surfaces.WATER
	w.load = 1750.0
	_check(WheelFx._rates(w, 0.0).is_equal_approx(water * 0.5), "half contact load must halve emission")
	w.load = 0.0
	_check(WheelFx._rates(w, 0.0) == Vector3.ZERO, "unloaded contacts must not emit")
	w.load = 3500.0
	w.contact = false
	_check(WheelFx._rates(w, 0.0) == Vector3.ZERO, "spinning airborne wheels must not emit")
	w.contact = true
	w.vx = 0.0
	w.vy = 0.0
	w.omega = 0.0
	w.slide = 0.0
	for surface in [Surfaces.GRAVEL, Surfaces.LOOSE, Surfaces.GRASS, Surfaces.DIRT, Surfaces.WATER, Surfaces.ASPHALT, Surfaces.MUD]:
		w.surface = surface
		_check(WheelFx._rates(w, 0.0) == Vector3.ZERO, "a stationary non-spinning wheel must not emit")


func _check_mesh() -> void:
	var mesh := WheelFx._debris_mesh()
	_check(mesh.get_surface_count() == 1, "solid debris must remain a single draw surface")
	var data := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = data[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = data[Mesh.ARRAY_NORMAL]
	_check(vertices.size() == 24 and normals.size() == 24, "debris must use eight triangles, below the old box's twelve")
	for i in range(0, vertices.size(), 3):
		var a := vertices[i]
		var b := vertices[i + 1]
		var c := vertices[i + 2]
		var n := (c - a).cross(b - a)
		_check(n.length() > 0.01, "debris contains a degenerate face")
		_check(n.dot((a + b + c) / 3.0) > 0.0, "debris winding points inwards")
		_check(normals[i].dot(n.normalized()) > 0.999, "debris face normal disagrees with its winding")
		_check(minf(absf(n.x), minf(absf(n.y), absf(n.z))) > 0.01, "debris must not have the old axis-aligned rectangular faces")


func _check_emitters() -> void:
	var car := Car.new()
	car.freeze = true
	car.set_process(false)
	car.set_physics_process(false)
	for i in 4:
		var w := Car.Wheel.new()
		w.contact = true
		w.load = 3500.0
		w.vx = 12.0
		w.omega = (12.0 + float(i) * 2.0) / w.radius
		w.point = Vector3(float(i) * 2.0, 0.0, 0.0)
		w.surface = i
		car.wheels.append(w)
	# Compare the actual engine's constructor RNG consumption, not an assumed
	# number of randi() calls inside its C++ implementation.
	seed(8753)
	var expected_seeds: Array[int] = []
	for i in 6:
		var particle := GPUParticles3D.new()
		expected_seeds.append(particle.seed)
		particle.free()
	var expected_next := randi()
	seed(8753)
	var fx := WheelFx.new(car)
	_check(randi() == expected_next, "wheel effects changed the original six-emitter global RNG footprint")
	_check(fx.get_child_count() == 6, "surface variants must not multiply emitter count")
	for i in 6:
		var emitter := fx.get_child(i) as GPUParticles3D
		_check(emitter.seed == expected_seeds[i], "effect emitter construction order changed")
		_check(not emitter.local_coords, "old debris must stay in world space")
		_check(emitter.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "particles must not add shadow draws")
	var totals := Vector3i.ZERO
	for e in fx._dust: totals.x += e.amount
	for e in fx._debris: totals.y += e.amount
	for e in fx._spray: totals.z += e.amount
	_check(totals == Vector3i(280, 96, 240), "total dust/debris/spray capacity changed")
	var world := Node3D.new()
	root.add_child(world)
	world.add_child(car)
	world.add_child(fx)
	fx.set_physics_process(false)
	fx._physics_process(1.0 / 120.0)
	for pm in fx._materials:
		var frames: Array = pm.get_shader_parameter("wheel_frames")
		var launches: PackedVector4Array = pm.get_shader_parameter("wheel_launches")
		var rates: PackedVector3Array = pm.get_shader_parameter("wheel_rates")
		_check(frames.size() == 4 and launches.size() == 4 and rates.size() == 4, "a material lost one of the four contact inputs")
		for i in 4:
			var frame: Projection = frames[i]
			_check(Vector3(frame.w.x, frame.w.y, frame.w.z).is_equal_approx(car.wheels[i].point + Vector3.UP * 0.05), "effect origin does not follow this wheel contact")
			_check(int(launches[i].w) == car.wheels[i].surface, "surface is not routed independently per wheel")
	var old_mesh := fx._debris[0].draw_pass_1
	var old_material := fx._debris[0].process_material
	car.wheels[0].contact = false
	car.wheels[1].surface = Surfaces.WATER
	car.wheels[2].surface = Surfaces.GRASS
	fx._physics_process(1.0 / 120.0)
	var rates: PackedVector3Array = fx._materials[0].get_shader_parameter("wheel_rates")
	_check(rates[0] == Vector3.ZERO, "lost front contact still emits")
	_check(rates[1].x == 0.0 and rates[1].y == 0.0 and rates[1].z > 0.0, "front water contact does not get spray")
	_check(rates[2].y > 0.0, "rear grass contact does not get clippings")
	_check(fx._debris[0].draw_pass_1 == old_mesh and fx._debris[0].process_material == old_material, "surface changes replaced the mesh/material of live particles")
	world.free()


func _check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)
