class_name PerfProbe
extends Node
## `--perf`: every two seconds prints where the frame goes, so a slow machine
## can say what is slow: frame rate, script and physics time on the CPU, and
## per split-screen view the CPU and GPU time of drawing it, with draw calls
## and triangles for the whole frame.

var _views: Array[SubViewport] = []
var _t := 0.0
var _frames := 0
var _proc_sum := 0.0
var _phys_sum := 0.0
var _wall_usec := 0
var _wall_ms := 0.0
## --benchmark N: discard 120 rendered frames, measure N, print JSON and quit.
## Wall time stays meaningful with --fixed-fps (which fixes the bot route).
var benchmark_frames := 0
var _warmup := 120
var _last_usec := 0
var _samples: Array[float] = []
var _draws_sum := 0.0
var _tris_sum := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


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
	_proc_sum += Performance.get_monitor(Performance.TIME_PROCESS)
	_phys_sum += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
	if _t < 2.0:
		return
	var line := "perf fps %.1f process %.1f ms physics %.1f ms draws %d tris %dk" % [
		_frames * 1000.0 / maxf(_wall_ms, 0.001),
		_proc_sum / _frames * 1000.0,
		_phys_sum / _frames * 1000.0,
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME) / 1000,
	]
	_views = _views.filter(func(v): return is_instance_valid(v))
	for i in _views.size():
		var rid := _views[i].get_viewport_rid()
		line += " | view %d %dx%d cpu %.1f gpu %.1f ms" % [i, _views[i].size.x, _views[i].size.y, RenderingServer.viewport_get_measured_render_time_cpu(rid), RenderingServer.viewport_get_measured_render_time_gpu(rid)]
	var root := get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(root, true)
	line += " | window gpu %.1f ms" % RenderingServer.viewport_get_measured_render_time_gpu(root)
	print(line)
	_t = 0.0
	_frames = 0
	_proc_sum = 0.0
	_phys_sum = 0.0
	_wall_ms = 0.0


func _benchmark() -> void:
	var now := Time.get_ticks_usec()
	var elapsed := (now - _last_usec) / 1000.0
	_last_usec = now
	if _warmup > 0:
		_warmup -= 1
		return
	_samples.append(elapsed)
	_draws_sum += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	_tris_sum += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	if _samples.size() < benchmark_frames:
		return
	var total := 0.0
	for ms in _samples:
		total += ms
	_samples.sort()
	print("benchmark ", JSON.stringify({
		"engine": Engine.get_version_info().string,
		"gpu": RenderingServer.get_video_adapter_name(),
		"frames": _samples.size(), "views": _views.size(),
		"fps": _samples.size() * 1000.0 / total,
		"mean_ms": total / _samples.size(),
		"p50_ms": _samples[int((_samples.size() - 1) * 0.5)],
		"p95_ms": _samples[int((_samples.size() - 1) * 0.95)],
		"p99_ms": _samples[int((_samples.size() - 1) * 0.99)],
		"draws": _draws_sum / _samples.size(),
		"triangles": _tris_sum / _samples.size(),
	}))
	benchmark_frames = 0
	get_tree().quit()
