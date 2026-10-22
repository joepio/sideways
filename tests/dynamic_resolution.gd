extends SceneTree
## Pure GPU-load controller checks; no renderer or wall-FPS performance claim.
## godot --headless --path . --script res://tests/dynamic_resolution.gd

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_check_initial_and_manual()
	_check_gpu_measurements()
	_check_pressure_and_recovery()
	_check_suspension_and_noise()
	_check_rng()
	if _failures == 0:
		print("dynamic resolution: %d checks passed; total-output budget, GPU-only filtering, cooldowns, bounds and manual isolation" % _checks)
	quit(1 if _failures else 0)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


func _feed(controller: DynamicResolution, count: int, milliseconds: float, seconds := 0.05) -> int:
	var changes := 0
	for _i in count:
		if controller.sample(seconds, milliseconds):
			changes += 1
	return changes


func _auto() -> DynamicResolution:
	var controller := DynamicResolution.new()
	controller.configure("auto", Vector2i(3840, 2160))
	return controller


func _check_initial_and_manual() -> void:
	_expect(DynamicResolution.initial_scale(Vector2i(3840, 2160)) == 0.75, "4K must start at 75 percent")
	_expect(DynamicResolution.initial_scale(Vector2i(1920, 1080)) == 1.0, "1080p must start native")
	_expect(DynamicResolution.initial_scale(Vector2i(2560, 1440)) == 1.0, "1440p fits the initial total pixel budget")
	_expect(DynamicResolution.initial_scale(Vector2i(7680, 4320)) == 0.5, "Initial scale must respect the 50 percent floor")
	_expect(DynamicResolution.initial_scale(Vector2i.ZERO) == 1.0, "Unknown size must not divide by zero")
	var controller := _auto()
	for pair in [["100%", 1.0], ["75%", 0.75], ["67%", 0.67], ["50%", 0.5]]:
		controller.configure(pair[0], Vector2i(3840, 2160))
		_expect(controller.scale == pair[1], "Manual selection must be exact")
		_expect(_feed(controller, 400, 80.0) == 0, "High GPU load changed a manual selection")
		_expect(_feed(controller, 400, 0.5) == 0, "Low GPU load changed a manual selection")
		_expect(controller.scale == pair[1], "Manual selection drifted")
	controller.configure("auto", Vector2i(3840, 2160))
	_expect(controller.scale == 0.75, "Returning to auto must start with the total-output budget")
	controller.configure("auto", Vector2i(1920, 1080))
	_expect(controller.scale == 1.0, "Resize to 1080p must restore native initial quality")


func _check_gpu_measurements() -> void:
	_expect(is_equal_approx(DynamicResolution.total_gpu_ms(0.5, [1.0, 2.0, 3.0, 4.0]), 10.5), "GPU signal must include root and all four views exactly once")
	_expect(DynamicResolution.total_gpu_ms(0.5, []) < 0.0, "Empty view set must be invalid")
	for bad in [0.0, -1.0, NAN, INF, 101.0]:
		_expect(DynamicResolution.total_gpu_ms(bad, [1.0]) < 0.0, "Invalid root GPU timing was accepted")
		_expect(DynamicResolution.total_gpu_ms(0.5, [1.0, bad, 1.0, 1.0]) < 0.0, "One invalid view must invalidate the complete GPU sum")
	_expect(DynamicResolution.total_gpu_ms(50.0, [51.0]) < 0.0, "A stalled aggregate must not drive adaptation")


func _check_pressure_and_recovery() -> void:
	var controller := _auto()
	_expect(_feed(controller, 38, 20.0) == 0, "Quality changed before settling plus two high windows")
	_expect(_feed(controller, 10, 20.0) == 1 and controller.scale == 0.67, "Sustained GPU pressure must lower exactly one level")
	_expect(_feed(controller, 24, 20.0) == 0, "Quality changed again before cooldown and fresh samples")
	_expect(_feed(controller, 600, 20.0) > 0 and controller.scale == 0.5, "Sustained pressure must reach, but never exceed, the lower bound")
	_expect(_feed(controller, 200, 20.0) == 0 and controller.scale == 0.5, "Minimum scale must stay bounded")
	controller.suspend()
	_expect(_feed(controller, 70, 1.0) == 0, "Quality recovery must wait for prolonged headroom")
	_expect(_feed(controller, 20, 1.0) == 1 and controller.scale == 0.55, "Quality should recover one level after prolonged headroom")
	_expect(_feed(controller, 60, 1.0) == 0, "Quality increase cooldown is too short")
	_feed(controller, 1600, 1.0)
	_expect(controller.scale == 1.0, "Stable headroom must eventually recover native quality")
	_expect(_feed(controller, 200, 1.0) == 0, "Native upper bound must remain stable")


func _check_suspension_and_noise() -> void:
	var controller := _auto()
	_feed(controller, 38, 20.0)
	controller.suspend()
	_expect(_feed(controller, 38, 20.0) == 0 and controller.scale == 0.75, "Suspension must discard stale pressure before resume")
	_feed(controller, 10, 20.0)
	var current := controller.scale
	controller.configure("auto", Vector2i(3840, 2160))
	controller.suspend() # Reseating at the same output starts fresh timings.
	_expect(controller.scale == current, "Reseating must not reset learned quality")
	_expect(_feed(controller, 38, 20.0) == 0, "A new view set must settle before adaptation")
	for bad in [0.0, -1.0, NAN, INF, 101.0]:
		_expect(not controller.sample(0.05, bad) and controller.scale == current, "Invalid GPU data changed quality")
	for gap in [0.0, -1.0, NAN, INF, 0.3]:
		_expect(not controller.sample(gap, 20.0) and controller.scale == current, "Invalid/stalled sample interval changed quality")
	controller = _auto()
	_expect(_feed(controller, 400, 7.5) == 0, "Budget deadband must not oscillate")
	controller.sample(0.05, 60.0)
	_expect(_feed(controller, 100, 7.5) == 0 and controller.scale == 0.75, "A single GPU spike must not lower quality")
	# Slow CPU delivery is not GPU pressure. Even at 10 samples/s this GPU
	# load cannot request a decrease; the controller never receives wall FPS.
	controller = _auto()
	_feed(controller, 100, 2.0, 0.1)
	_expect(controller.scale >= 0.75, "CPU-only slow delivery lowered resolution")
	# A marginal next-level cost should stay put rather than bounce upward.
	controller = _auto()
	_expect(_feed(controller, 500, 5.7) == 0 and controller.scale == 0.75, "Recovery ignored predicted next-level pixel cost")


func _check_rng() -> void:
	seed(85729)
	var expected := randi()
	seed(85729)
	var controller := _auto()
	_feed(controller, 300, 20.0)
	_feed(controller, 300, 1.0)
	_expect(randi() == expected, "Render controller consumed global gameplay RNG")
