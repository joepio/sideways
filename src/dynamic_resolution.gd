class_name DynamicResolution
extends RefCounted
## GPU-only resolution controller. Elapsed time controls filtering/cooldowns,
## never a wall-FPS estimate: a CPU bottleneck alone cannot reduce resolution.
## Viewport timestamps omit some GPU work (including final screen blit), so
## reserve 10% of the 120 Hz budget. This is a load target, not an FPS promise.

const LEVELS := [0.5, 0.55, 0.6, 0.67, 0.75, 0.85, 1.0]
const GPU_BUDGET_MS := 1000.0 / 120.0 * 0.9
const INITIAL_PIXELS := 3840.0 * 2160.0 * 0.75 * 0.75
const WINDOW_SECONDS := 0.5
const SETTLE_SECONDS := 1.0
const DOWN_COOLDOWN := 1.25
const UP_COOLDOWN := 4.0
const MAX_SAMPLE_GAP := 0.25
const MAX_GPU_MS := 100.0

var scale := 1.0
var choice := ""
var output_size := Vector2i.ZERO
var smoothed_gpu_ms := 0.0
var last_gpu_ms := 0.0
var reason := "initial"
var _elapsed := 0.0
var _settle := SETTLE_SECONDS
var _window_time := 0.0
var _window_sum := 0.0
var _window_samples := 0
var _high_windows := 0
var _low_time := 0.0


static func initial_scale(size: Vector2i) -> float:
	if size.x < 2 or size.y < 2:
		return 1.0
	var ideal := sqrt(INITIAL_PIXELS / (float(size.x) * float(size.y)))
	var result := float(LEVELS[0])
	for level: float in LEVELS:
		if level <= ideal + 0.000001:
			result = level
	return result


## Do not accept a partial sum: a missing/stale disabled view must not look
## like spare GPU budget. Active-set changes are invalidated by the caller.
static func total_gpu_ms(root_ms: float, view_ms: Array[float]) -> float:
	if view_ms.is_empty() or not _valid_gpu(root_ms):
		return -1.0
	var total := root_ms
	for value in view_ms:
		if not _valid_gpu(value):
			return -1.0
		total += value
	return total if _valid_gpu(total) else -1.0


static func _valid_gpu(value: float) -> bool:
	return is_finite(value) and value > 0.0 and value <= MAX_GPU_MS


func configure(selection: String, size: Vector2i) -> void:
	if selection == choice and size == output_size:
		return
	choice = selection
	output_size = size
	match choice:
		"100%": scale = 1.0
		"75%": scale = 0.75
		"67%": scale = 0.67
		"50%": scale = 0.5
		_: scale = initial_scale(size)
	reason = "configured"
	suspend()


## Retain current quality while menus/loading/hidden windows are inactive.
## Drop old asynchronous timestamps and wait for the new view set to settle.
func suspend() -> void:
	_elapsed = 0.0
	_settle = SETTLE_SECONDS
	smoothed_gpu_ms = 0.0
	last_gpu_ms = 0.0
	_reset_window()
	_high_windows = 0
	_low_time = 0.0


func sample(seconds: float, gpu_ms: float) -> bool:
	if choice != "auto":
		return false
	if not is_finite(seconds) or seconds <= 0.0 or seconds > MAX_SAMPLE_GAP or not _valid_gpu(gpu_ms):
		suspend()
		return false
	_elapsed += seconds
	last_gpu_ms = gpu_ms
	if _settle > 0.0:
		_settle -= seconds
		return false
	_window_time += seconds
	_window_sum += gpu_ms * seconds
	_window_samples += 1
	if _window_time < WINDOW_SECONDS or _window_samples < 8:
		return false
	var window_ms := _window_sum / _window_time
	var duration := _window_time
	_reset_window()
	smoothed_gpu_ms = window_ms if smoothed_gpu_ms == 0.0 else lerpf(smoothed_gpu_ms, window_ms, 0.5)
	var index := LEVELS.find(scale)
	# Both fresh and filtered load must be high for two complete windows.
	if window_ms > GPU_BUDGET_MS * 1.08 and smoothed_gpu_ms > GPU_BUDGET_MS * 1.08:
		_high_windows += 1
	else:
		_high_windows = 0
	if window_ms < GPU_BUDGET_MS * 0.78 and smoothed_gpu_ms < GPU_BUDGET_MS * 0.78:
		_low_time += duration
	else:
		_low_time = 0.0
	if _high_windows >= 2 and _elapsed >= DOWN_COOLDOWN and index > 0:
		return _change(index - 1, "gpu pressure")
	if _low_time >= 3.0 and _elapsed >= UP_COOLDOWN and index < LEVELS.size() - 1:
		var next_scale: float = LEVELS[index + 1]
		# Conservative pixel-cost prediction prevents a large quality step from
		# immediately overshooting. Non-pixel GPU work makes this overestimate.
		var predicted_ms := smoothed_gpu_ms * pow(next_scale / scale, 2.0)
		if predicted_ms <= GPU_BUDGET_MS * 0.92:
			return _change(index + 1, "gpu headroom")
	return false


func _change(index: int, why: String) -> bool:
	scale = LEVELS[index]
	reason = why
	_elapsed = 0.0
	_settle = SETTLE_SECONDS
	_high_windows = 0
	_low_time = 0.0
	_reset_window()
	# Start a fresh filter after render-target/history reconstruction.
	smoothed_gpu_ms = 0.0
	return true


func _reset_window() -> void:
	_window_time = 0.0
	_window_sum = 0.0
	_window_samples = 0
