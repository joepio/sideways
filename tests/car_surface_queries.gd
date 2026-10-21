extends SceneTree
## A reset invalidates per-wheel road hints. A physics tick shares one
## centre water sample between tyre classification and body drag.

class WaterProbe:
	extends Car
	var sample_level := -INF
	var water_calls := 0
	var suspension_calls := 0
	var last_suspension_level := -INF
	var checked_ticks := 0
	var errors: Array[String] = []

	func sample_water(_x: float, _z: float) -> float:
		water_calls += 1
		return sample_level


	func _suspension(state: PhysicsDirectBodyState3D, xf: Transform3D, dt: float, level: float) -> void:
		suspension_calls += 1
		last_suspension_level = level
		super._suspension(state, xf, dt, level)


	func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
		var before_water := water_calls
		var before_suspension := suspension_calls
		var resetting := _teleport
		var has_water := water_at.is_valid()
		var level := sample_level if has_water else -INF
		var bottom: float = state.transform.origin.y - spec.wheel_radius
		super._integrate_forces(state)
		var expected_calls := 1 if has_water and not resetting else 0
		if water_calls - before_water != expected_calls:
			errors.append("expected %d centre water calls, got %d" % [expected_calls, water_calls - before_water])
		if not resetting:
			checked_ticks += 1
			if suspension_calls - before_suspension != 1 or last_suspension_level != level:
				errors.append("suspension did not receive this tick's centre water sample")
			if wading != maxf(level - bottom, 0.0):
				errors.append("body drag did not reuse this tick's centre water sample")


var _failed := false
var _checks := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var world := Node3D.new()
	root.add_child(world)
	_check_reset_and_surface(world)
	var probe := WaterProbe.new()
	probe.setup("rally2")
	probe.gravity_scale = 0.0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.75, 0.7, 4.0)
	shape.shape = box
	shape.position.y = 0.45
	probe.add_child(shape)
	probe.position = Vector3(1.0, 2.0, 3.0)
	probe.water_at = probe.sample_water
	world.add_child(probe)
	# Dry, shallow and deeper samples must be refreshed every tick.
	for level in [-INF, 1.9, 2.4]:
		probe.sample_level = level
		for _tick in 8:
			await physics_frame
	probe.water_at = Callable()
	for _tick in 8:
		await physics_frame
	probe.water_at = probe.sample_water
	for w in probe.wheels:
		w.road_hint = 170
	probe.teleport(Transform3D(Basis.IDENTITY, Vector3(5.0, 2.0, 7.0)))
	for w in probe.wheels:
		_check(w.road_hint == -1, "live reset did not clear a wheel hint")
	for _tick in 8:
		await physics_frame
	_check(probe.checked_ticks >= 24, "not enough physics ticks exercised")
	for error in probe.errors:
		_check(false, error)
	_check(probe.errors.is_empty(), "water sharing failed during physics integration")
	var ticks := probe.checked_ticks
	world.free()
	if not _failed:
		print("car surface queries: %d checks and %d physics ticks passed" % [_checks, ticks])
	quit(1 if _failed else 0)


func _check_reset_and_surface(world: Node3D) -> void:
	# A stale hint's 60-point window ends 22 m behind this reset position.
	# The existing 30 m early return would select the old, narrower road.
	var stage := Stage.new()
	for i in 80:
		stage.points.append(Vector3(0.0, 0.0, -i * Stage.STEP))
		stage.dirs.append(Vector3.FORWARD)
		stage.widths.append(3.0 if i < 40 else 4.0)
	stage._index()
	var p := Vector3(2.5, 0.0, -80.0)
	_check(stage.surface_near(p, 0).x == Surfaces.LOOSE, "stale hint fixture no longer exercises the old road window")
	_check(stage.surface_near(p, -1) == Vector2i(Surfaces.GRAVEL, 40), "reset position should lie on the wider gravel road")
	var car := Car.new()
	car.setup("rally2")
	car.freeze = true
	car.surface_at = stage.surface_near
	world.add_child(car)
	for w in car.wheels:
		w.road_hint = 0
	car.teleport(Transform3D(Basis.IDENTITY, p))
	var road := Node3D.new()
	road.set_meta("road", true)
	for w in car.wheels:
		_check(w.road_hint == -1, "teleport did not clear a wheel hint")
		_check(car._surface(w, road, p, -INF) == Surfaces.GRAVEL, "first contact after reset used the old road width")
		_check(w.road_hint == 40, "first contact did not store its new road hint")
		_check(car._surface(w, road, p + Vector3.FORWARD * Stage.STEP, -INF) == Surfaces.GRAVEL, "following contact lost its local hint")
		_check(w.road_hint == 41, "following contact did not advance its hint")
	# Preserve the incoming centre-sampling approximation and strict threshold:
	# classification uses the supplied level, regardless of wheel x/z.
	var wheel: Car.Wheel = car.wheels[0]
	_check(car._surface(wheel, road, p, 0.08) == Surfaces.GRAVEL, "water threshold changed at equality")
	_check(car._surface(wheel, road, p, 0.0801) == Surfaces.WATER, "water threshold changed above equality")
	_check(car._surface(wheel, road, p + Vector3(5.0, 0.0, 0.0), 0.0801) == Surfaces.WATER, "supplied centre water level was not preserved")
	road.free()
	car.free()
	stage.free()


func _check(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_failed = true
		push_error(message)
