class_name PerfProbe
extends Node
## `--perf`: wall fps, cached CPU peak monitors and per-view CPU/GPU draw times.
## TIME_PROCESS and TIME_PHYSICS_PROCESS are cached maxima updated once a second,
## not individual-frame costs; TIME_PROCESS includes waiting on the renderer.
## Renderer setup CPU time is separate. Primitive counts are engine-reported.

var _views: Array[SubViewport] = []
var _t := 0.0
var _frames := 0
var _wall_usec := 0
var _wall_ms := 0.0
## --benchmark N: discard benchmark_warmup rendered frames, measure N and quit.
## Wall time stays meaningful with --fixed-fps (which fixes the bot route).
## --debug --benchmark-profile profiles only the measured frames (diagnostic run).
var benchmark_frames := 0
var benchmark_warmup := 120
var car_count := 0
var _benchmark_profile := false
var _warmup := 0
var _last_usec := 0
var _samples: Array[float] = []
var _draws_sum := 0.0
var _tris_sum := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_warmup = benchmark_warmup
	_benchmark_profile = OS.get_cmdline_user_args().has("--benchmark-profile")
	if _benchmark_profile:
		if benchmark_frames <= 0 or not EngineDebugger.is_active() or not EngineDebugger.has_profiler("scripts"):
			push_error("--benchmark-profile requires --benchmark N and --debug (local scripts profiler).")
			set_process(false)
			get_tree().quit(1)
			return
		# If --profiling was also supplied, discard its startup/warmup collection.
		if EngineDebugger.is_profiling("scripts"):
			EngineDebugger.profiler_enable.call_deferred("scripts", false)


func watch(vp: SubViewport) -> void:
	RenderingServer.viewport_set_measure_render_time(vp.get_viewport_rid(), true)
	_views.append(vp)


func _process(delta: float) -> void:
	var now := Time.get_ticks_usec()
	if _wall_usec > 0:
		_wall_ms += (now - _wall_usec) / 1000.0
	_wall_usec = now
	if benchmark_frames > 0:
		_benchmark()
	_t += delta
	_frames += 1
	if _t < 2.0:
		return
	var line := "perf fps %.1f process_cached_peak %.1f ms physics_cached_peak %.1f ms draws %d engine_primitives %dk" % [
		_frames * 1000.0 / maxf(_wall_ms, 0.001),
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME) / 1000,
	]
	_views = _views.filter(func(v): return is_instance_valid(v))
	for i in _views.size():
		var rid := _views[i].get_viewport_rid()
		line += " | view %d %dx%d mode %d scale %.2f taa %s cpu %.1f gpu %.1f ms" % [i, _views[i].size.x, _views[i].size.y, _views[i].scaling_3d_mode, _views[i].scaling_3d_scale, _views[i].use_taa, RenderingServer.viewport_get_measured_render_time_cpu(rid), RenderingServer.viewport_get_measured_render_time_gpu(rid)]
	var root := get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(root, true)
	line += " | window gpu %.1f ms | render setup cpu %.1f ms" % [RenderingServer.viewport_get_measured_render_time_gpu(root), RenderingServer.get_frame_setup_time_cpu()]
	print(line)
	_t = 0.0
	_frames = 0
	_wall_ms = 0.0


func _benchmark() -> void:
	var now := Time.get_ticks_usec()
	var had_previous_frame := _last_usec > 0
	var elapsed := (now - _last_usec) / 1000.0
	_last_usec = now
	if _warmup > 0:
		_warmup -= 1
		if _warmup == 0 and _benchmark_profile:
			# Toggle natively after GDScript returns: enabling inside an active
			# script call gives it an invalid zero entry timestamp in Godot 4.5.
			EngineDebugger.profiler_enable.call_deferred("scripts", true)
		return
	# With zero warmup, the first callback establishes the wall-time interval.
	if not had_previous_frame:
		if _benchmark_profile:
			EngineDebugger.profiler_enable.call_deferred("scripts", true)
		return
	_samples.append(elapsed)
	_draws_sum += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	_tris_sum += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	if _samples.size() < benchmark_frames:
		return
	benchmark_frames = 0
	if _benchmark_profile:
		# FIFO deferred calls finish this frame's script work, print its
		# accumulated profile, then read back the output outside profiling.
		EngineDebugger.profiler_enable.call_deferred("scripts", false)
		_finish_benchmark.call_deferred()
	else:
		_finish_benchmark()


func _finish_benchmark() -> void:
	var total := 0.0
	for ms in _samples:
		total += ms
	_samples.sort()
	var root_output_size := Vector2i.ZERO
	var root_texture_reported_size := Vector2i.ZERO
	var root_output_size_available := false
	# ViewportTexture.get_size() applies root stretch again in Godot 4.5.2.
	# The image reports actual pixels. Read it once, after the final wall sample.
	if DisplayServer.get_name() != "headless":
		var root_texture := get_viewport().get_texture()
		if root_texture != null:
			root_texture_reported_size = Vector2i(root_texture.get_size())
			var root_image := root_texture.get_image()
			if root_image != null and not root_image.is_empty():
				root_output_size = root_image.get_size()
				root_output_size_available = true
	var window_size := DisplayServer.window_get_size()
	var viewports: Array[Dictionary] = []
	for vp in _views:
		if not is_instance_valid(vp):
			continue
		viewports.append({
			"size": [vp.size.x, vp.size.y],
			"size_2d_override": [vp.size_2d_override.x, vp.size_2d_override.y],
			"size_2d_override_stretch": vp.size_2d_override_stretch,
			"scaling_3d_mode": vp.scaling_3d_mode,
			"scaling_3d_scale": vp.scaling_3d_scale,
			"use_taa": vp.use_taa,
		})
	print("benchmark ", JSON.stringify({
		"engine": Engine.get_version_info().string,
		"gpu": RenderingServer.get_video_adapter_name(),
		"frames": _samples.size(), "views": viewports.size(),
		"cars": car_count,
		"warmup_frames": benchmark_warmup,
		"benchmark_profile": _benchmark_profile,
		"physics_ticks_per_second": Engine.physics_ticks_per_second,
		"tyre_substeps": Car.SUBSTEPS,
		"window_size": [window_size.x, window_size.y],
		"root_output_size": [root_output_size.x, root_output_size.y],
		"root_output_size_available": root_output_size_available,
		"root_texture_reported_size": [root_texture_reported_size.x, root_texture_reported_size.y],
		"viewports": viewports,
		"fps": _samples.size() * 1000.0 / total,
		"mean_ms": total / _samples.size(),
		"p50_ms": _samples[int((_samples.size() - 1) * 0.5)],
		"p95_ms": _samples[int((_samples.size() - 1) * 0.95)],
		"p99_ms": _samples[int((_samples.size() - 1) * 0.99)],
		"draws": _draws_sum / _samples.size(),
		"engine_primitives": _tris_sum / _samples.size(),
		# Legacy key retained for existing result readers; this is the engine's primitive count.
		"triangles": _tris_sum / _samples.size(),
	}))
	get_tree().quit()
