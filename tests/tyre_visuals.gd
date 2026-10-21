extends SceneTree
## Compare cached tyre uniforms with the original transform calculation on
## the real imported and fallback models, including cache invalidation.

var _failed := false
var _checks := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	for model in ["rally2", "asti", "mv6", "toyama"]:
		var mount := Node3D.new()
		root.add_child(mount)
		var car := Car.new()
		car.setup(model)
		car.freeze = true
		mount.add_child(car)
		car.set_physics_process(false)
		CarModel.build(car, Color(0.6, 0.2, 0.1))
		_pose(car, 0)
		_check_car(car, model + " initial")
		var entries := {}
		for w in car.wheels:
			for tyre in w.tyres:
				_check(w.tyre_uniforms.has(tyre), model + " did not cache its normal layout")
				entries[tyre] = w.tyre_uniforms.get(tyre)
		for sample in range(1, 24):
			_pose(car, sample)
			_check_car(car, model + " pose %d" % sample)
			for w in car.wheels:
				for tyre in w.tyres:
					_check(is_same(entries[tyre], w.tyre_uniforms.get(tyre)), model + " refreshed rigid tyre constants")
		# A changed mesh binding, radius or parent scale must refresh constants.
		var wheel: Car.Wheel = car.wheels[0]
		var tyre: GeometryInstance3D = wheel.tyres[0]
		var original := tyre.transform
		tyre.transform = Transform3D(original.basis.scaled(Vector3.ONE * 0.9), Vector3(0.01, -0.02, 0.03))
		car._deform(wheel)
		_check_wheel(car, wheel, model + " mesh binding")
		_check(not is_same(entries[tyre], wheel.tyre_uniforms.get(tyre)), model + " kept stale mesh constants")
		wheel.radius *= 1.08
		car._deform(wheel)
		_check_wheel(car, wheel, model + " radius")
		mount.scale = Vector3.ONE * 1.1
		car._deform(wheel)
		_check_wheel(car, wheel, model + " uniform scale")
		# Distorted parents and unusual hierarchies retain the general path.
		mount.scale = Vector3(1.1, 0.9, 1.2)
		car._deform(wheel)
		_check_wheel(car, wheel, model + " nonuniform scale")
		_check(not wheel.tyre_uniforms.has(tyre), model + " cached a distorted layout")
		mount.scale = Vector3.ONE
		if wheel.spinner:
			wheel.spinner.position = Vector3(0.0, 0.04, 0.0)
			car._deform(wheel)
			_check_wheel(car, wheel, model + " offset spinner")
			_check(not wheel.tyre_uniforms.has(tyre), model + " cached an offset spinner")
			wheel.spinner.position = Vector3.ZERO
		tyre.top_level = true
		car._deform(wheel)
		_check_wheel(car, wheel, model + " independent tyre")
		_check(not wheel.tyre_uniforms.has(tyre), model + " cached an independent tyre")
		tyre.top_level = false
		tyre.transform = original
		car._deform(wheel)
		_check_wheel(car, wheel, model + " restored layout")
		_check(wheel.tyre_uniforms.has(tyre), model + " did not recache its restored layout")
		mount.free()
	if not _failed:
		print("tyre visuals: %d checks passed across imported and fallback models" % _checks)
	quit(1 if _failed else 0)


func _pose(car: Car, sample: int) -> void:
	car.transform = Transform3D(Basis.from_euler(Vector3(sample * 0.09, sample * 0.37, sample * -0.06)), Vector3(sample * 43.0, sample * 1.4, sample * -21.0))
	for i in car.wheels.size():
		var w := car.wheels[i]
		w.spin = sample * 0.73 + i * 0.2
		w.steer = sin(sample * 0.4 + i) * 0.45
		w.compression = 0.1 + 0.09 * sin(sample * 0.7 + i)
		w.contact = sample % 5 != 0
		w.load = 2000.0 + sample * 700.0
		w.fy = cos(sample * 0.6 + i) * 9000.0
	car._physics_process(1.0 / 240.0)


func _check_car(car: Car, label: String) -> void:
	for w in car.wheels:
		_check_wheel(car, w, label)


func _check_wheel(car: Car, w: Car.Wheel, label: String) -> void:
	var squash := clampf(w.load / Car.TYRE_RATE, 0.0, 0.06) if w.contact else 0.0
	var lean := clampf(w.fy / Car.WALL_RATE, -0.05, 0.05) if w.contact else 0.0
	var down := -car.global_basis.y
	var axle: Vector3 = car.global_basis * (Basis(Vector3.UP, w.steer) * Vector3.RIGHT)
	for tyre in w.tyres:
		var inv := tyre.global_basis.inverse()
		var scale_ := tyre.global_basis.get_scale().x
		var expected := {
			"contact_dir": (inv * down).normalized(),
			"axle_dir": (inv * axle).normalized(),
			"hub": tyre.global_transform.affine_inverse() * w.node.global_position,
			"radius": w.radius / scale_,
			"squash": squash / scale_,
			"lean": lean / scale_,
		}
		for key in expected:
			var actual: Variant = tyre.get_instance_shader_parameter(key)
			if expected[key] is Vector3:
				# The uncached world-space inverse loses submillimetre precision
				# far from the origin; the retained local hub avoids that jitter.
				var tolerance := 0.001 / absf(scale_) if key == "hub" else 0.00001
				if actual is Vector3:
					var vector: Vector3 = actual
					_check(vector.distance_to(expected[key]) <= tolerance, label + " " + key)
				else:
					_check(false, label + " " + key)
			else:
				_check(actual is float and is_equal_approx(actual, expected[key]), label + " " + key)


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_failed = true
		push_error("Tyre visual regression: " + label)
