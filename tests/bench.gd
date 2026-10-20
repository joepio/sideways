extends SceneTree
## Drives the car through the classic handling tests on flat gravel and
## prints the numbers, so a physics change shows what it did:
##   godot --headless --path . --script res://tests/bench.gd
## Fails when a number leaves its sane range.

const HZ := 240.0
var world: Node3D
var car: Car
var t := 0.0
var phase := "rest"
var results := {}
var marks := {}
var start_pos := Vector3.ZERO
var failed := false


func _initialize() -> void:
	Engine.physics_ticks_per_second = int(HZ)
	world = Node3D.new()
	root.add_child(world)
	var ground := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(6000, 2, 6000)
	shape.shape = box
	shape.position.y = -1
	ground.add_child(shape)
	ground.set_meta("surface", Surfaces.GRAVEL)
	world.add_child(ground)
	_new_car()


func _new_car() -> void:
	if car:
		car.queue_free()
	car = Car.new()
	car.setup("rally2")
	var cs := CollisionShape3D.new()
	var b := BoxShape3D.new()
	b.size = Vector3(1.75, 0.7, 4.0)
	cs.shape = b
	cs.position.y = 0.45
	car.add_child(cs)
	world.add_child(car)
	car.global_position = Vector3(0, 0.36, 0)
	t = 0.0


func _physics_process(delta: float) -> bool:
	t += delta
	var kmh := car.linear_velocity.length() * 3.6
	match phase:
		"rest":
			if t > 3.0:
				results["rest_drift_cm"] = snappedf(Vector2(car.global_position.x, car.global_position.z).length() * 100.0, 0.01)
				results["ride_height"] = snappedf(car.global_position.y, 0.001)
				phase = "launch"
				t = 0.0
				start_pos = car.global_position
		"launch":
			car.throttle = 1.0
			car.steer_input = 0.0
			for target in [60, 100, 160]:
				if kmh >= target and not marks.has(target):
					marks[target] = true
					results["0-%d_s" % target] = snappedf(t, 0.01)
			if t > 45.0:
				results["top_kmh"] = snappedf(kmh, 0.1)
				results["top_gear"] = car.gear
				results["shifts"] = car.stats.shifts
				phase = "to100"
				_new_car()
				t = 0.0
		"to100":
			car.throttle = 1.0
			if t > 1.0 and kmh >= 100.0:
				phase = "brake"
				start_pos = car.global_position
				t = 0.0
		"brake":
			car.throttle = 0.0
			car.brake = 1.0
			if kmh < 0.5:
				results["brake_100_m"] = snappedf(car.global_position.distance_to(start_pos), 0.1)
				results["brake_100_s"] = snappedf(t, 0.01)
				car.brake = 0.0
				phase = "skid"
				_new_car()
				t = 0.0
				marks.clear()
		"skid":
			# Steady circle: hold 50 km/h with throttle, steer to radius 40 m.
			var v := car.linear_velocity
			var speed := v.length()
			# Ramp the speed on a fixed lock until the tyres give up.
			var want := (30.0 + maxf(t - 6.0, 0.0) * 4.0) / 3.6
			car.throttle = clampf((want - speed) * 0.5, 0.0, 1.0)
			car.steer_input = -0.5 if t > 4.0 else 0.0
			if t > 6.0:
				var yaw := car.angular_velocity.y
				var lat_g := absf(yaw * speed) / 9.81
				results["skid_lat_g"] = maxf(results.get("skid_lat_g", 0.0), snappedf(lat_g, 0.01))
			if t > 22.0:
				results["skid_slip_deg"] = snappedf(car.stats.max_slip_angle, 0.1)
				phase = "hand"
				_new_car()
				t = 0.0
		"hand":
			# Handbrake turn from 60 km/h.
			if not marks.has("go"):
				car.throttle = 1.0
				if kmh > 60.0:
					marks["go"] = t
					results["hand_yaw_max"] = 0.0
			else:
				var since: float = t - marks["go"]
				car.throttle = 0.0
				car.handbrake = 1.0 if since < 0.8 else 0.0
				car.steer_input = -1.0 if since < 1.5 else 0.0
				results["hand_yaw_max"] = maxf(results["hand_yaw_max"], snappedf(absf(car.angular_velocity.y), 0.01))
				if since > 3.0:
					results["hand_heading_deg"] = snappedf(rad_to_deg(absf(car.global_basis.get_euler().y)), 1.0)
					_finish()
					return true
	return false


func _check(key: String, lo: float, hi: float) -> void:
	var v: float = results.get(key, NAN)
	if not (v >= lo and v <= hi):
		printerr("bench: %s = %s, want %s..%s" % [key, v, lo, hi])
		failed = true


func _finish() -> void:
	print("bench: ", JSON.stringify(results))
	_check("rest_drift_cm", 0.0, 3.0)
	_check("0-100_s", 3.5, 6.5)
	_check("top_kmh", 175.0, 215.0)
	_check("brake_100_m", 35.0, 60.0)
	_check("skid_lat_g", 0.65, 1.0)
	_check("hand_heading_deg", 60.0, 180.0)
	print("bench: ", "FAILED" if failed else "ok")
	quit(1 if failed else 0)
