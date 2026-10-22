extends SceneTree
## Focused input/camera and post-finish drivetrain regressions.
## godot --headless --path . --script res://tests/player_controls.gd
## No renderer/obstruction claim: actual orbit framing still needs a pad playtest.

const FIXTURE := """
extends "res://main.gd"
func _ready() -> void:
	pass
"""

class DriverProbe extends RefCounted:
	var saw_released_hold := false
	func drive(car: Car, _delta: float) -> void:
		saw_released_hold = not car.hold
		car.throttle = 0.3
		car.brake = 0.0

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	# Main's SDK autoload identifiers must be registered before fixture compilation.
	await process_frame
	var fixture_script := GDScript.new()
	fixture_script.source_code = FIXTURE
	if not _expect(fixture_script.reload() == OK, "Main fixture did not parse"):
		quit(1)
		return
	var game: Node = fixture_script.new()
	game.process_mode = Node.PROCESS_MODE_DISABLED
	root.add_child(game)
	_check_look(game)
	_check_finish(game)
	game.free()
	if _failures == 0:
		print("player controls: %d checks passed; radial look, per-player routing, return/reset and finish no-reverse" % _checks)
	quit(1 if _failures else 0)


func _check_look(game: Node) -> void:
	_expect(ChaseCamera.look_stick(Vector2(0.1, 0.1)) == Vector2.ZERO, "Radial centre drift must be ignored")
	var diagonal := ChaseCamera.look_stick(Vector2(0.12, 0.12))
	_expect(diagonal.length() > 0.0 and diagonal.x == diagonal.y, "Radial deadzone must not act as an axial square")
	_expect(ChaseCamera.look_stick(Vector2(1, 1)).is_equal_approx(Vector2(1, 1).normalized()), "Diagonal must be clamped without changing direction")
	_expect(ChaseCamera.look_stick(Vector2(INF, 0)) == Vector2.ZERO, "Invalid input must not contaminate the camera")
	var sdk := root.get_node("GameNight")
	var packet := {"axes": [31000, -22000, 16384, -8192, 0, 0]}
	var remote: Vector2 = sdk.call("stick", packet, 1, 0.0)
	var local := Vector2(16384.0 / 32767.0, -8192.0 / 32767.0)
	_expect(ChaseCamera.look_stick(remote).is_equal_approx(ChaseCamera.look_stick(local)), "Local and SDK right axes must get the same single deadzone")
	var first := ChaseCamera.new()
	var second := ChaseCamera.new()
	var roster: Array[Dictionary] = [
		{"camera": first, "held": {"look": Vector2.RIGHT}, "bot": false},
		{"camera": second, "held": {"look": Vector2.LEFT}, "bot": false},
	]
	game.set("players", roster)
	game.call("_apply_camera_look", false)
	_expect(first.look_input == Vector2.RIGHT and second.look_input == Vector2.LEFT, "Each seat must drive only its own camera")
	game.call("_apply_camera_look", true)
	_expect(first.look_input == Vector2.ZERO and second.look_input == Vector2.ZERO, "Menu/pause must clear both cameras")
	roster[0].bot = true
	game.call("_read", roster[0])
	game.call("_apply_camera_look", false)
	_expect(first.look_input == Vector2.ZERO, "Bot takeover must clear old human look input")
	first._pos = Vector3(4, 5, 6)
	first._vel = Vector3(1, 2, 3)
	first._heading = Vector3.FORWARD
	first.look_input = Vector2.ZERO
	first._advance_look(1.0 / 40.0)
	_expect(first._look_angles == Vector2.ZERO, "Fresh no-input camera must remain exactly at zero orbit")
	first.look_input = Vector2(0.7, 0.3)
	second.look_input = first.look_input
	for i in 120:
		first._advance_look(1.0 / 120.0)
	for i in 40:
		second._advance_look(1.0 / 40.0)
	_expect(first._look_angles.distance_to(second._look_angles) < 0.00002, "Look response must not depend materially on render cadence")
	_expect(first._pos == Vector3(4, 5, 6) and first._vel == Vector3(1, 2, 3) and first._heading == Vector3.FORWARD, "Orbit must not alter the free follow spring")
	var pivot := Vector3(0, 0.9, 0)
	var free_eye := Vector3(0, 2.05, 5.2)
	var eye := first._orbit_eye(pivot, free_eye)
	_expect(is_equal_approx(eye.distance_to(pivot), free_eye.distance_to(pivot)), "Unobstructed orbit must keep the boom length")
	first.look_input = Vector2.ZERO
	var previous := first._look_angles.length()
	for i in 240:
		first._advance_look(1.0 / 120.0)
		_expect(first._look_angles.length() <= previous, "Release must return without angular overshoot")
		previous = first._look_angles.length()
	_expect(first._look_angles == Vector2.ZERO, "Release must eventually restore the exact original path")
	first.mode = ChaseCamera.FAR
	first.look_input = Vector2.RIGHT
	first._advance_look(0.1)
	_expect(first._look_angles.x < 0.0, "Far camera must support look-right")
	# A directional look stick uses both axes for an orbit in the horizontal
	# plane. These match the player's cardinal expectations, not the mapping.
	for input in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
		first.look_input = input
		for frame in 240:
			first._advance_look(1.0 / 120.0)
		var view := first._orbit_eye(pivot, free_eye) - pivot
		if input == Vector2.RIGHT:
			_expect(view.x < -5.1 and absf(view.z) < 0.01, "Right stick must show the left flank, not the front")
		elif input == Vector2.LEFT:
			_expect(view.x > 5.1 and absf(view.z) < 0.01, "Left stick must show the right flank")
		elif input == Vector2.UP:
			_expect(view.z > 5.1 and absf(view.x) < 0.01, "Up stick must show the normal rear view")
		else:
			_expect(view.z < -5.1 and absf(view.x) < 0.01, "Down stick must show the front of the car")
		_expect(absf(view.y - (free_eye.y - pivot.y)) < 0.0001, "Directional look must not change camera elevation")
	first.mode = ChaseCamera.BONNET
	first._advance_look(0.1)
	_expect(first._look_angles == Vector2.ZERO, "Bonnet must remain attached and forward facing")
	first.mode = ChaseCamera.CHASE
	first._advance_look(0.1)
	first.snap()
	_expect(first._look_angles == Vector2.ZERO and first.look_input == Vector2.ZERO and first._snap, "Recovery/stage snap must clear orbit")
	roster.clear()
	first.free()
	second.free()


func _check_finish(game: Node) -> void:
	var stage := Stage.new()
	stage.finish = 10000.0
	game.set("stage", stage)
	var car := Car.new()
	car.setup("rally2")
	car.freeze = true
	root.add_child(car)
	# Negative control reproduces the reported mechanism in the real gearbox.
	car.throttle = 0.0
	car.brake = 0.6
	car.speed = 0.0
	for i in 180:
		car._gearbox(1.0 / 120.0)
	_expect(car.gear == -1, "Negative control no longer reproduces brake-to-reverse")
	var driver := DriverProbe.new()
	var player := {"car": car, "bot": true, "hint": -1, "along": 0.0, "ghost": 0.0,
		"finished": true, "ai": driver, "off_road": 0.0, "off_track": 0.0, "recover": false}
	for phase in ["racing", "results"]:
		game.set("phase", phase)
		for manual in [false, true]:
			car.manual = manual
			car.gear = -1
			car.shift_timer = 0.12
			car._shift_request = -1
			car.throttle = 1.0
			car.handbrake = 1.0
			car.linear_velocity = Vector3(0, 0, -12)
			var old_transform := car.global_transform
			var old_velocity := car.linear_velocity
			for wheel in car.wheels:
				wheel.omega = 20.0
			for tick in 120:
				game.call("_drive", player, 1.0 / 120.0)
				car._gearbox(1.0 / 120.0)
				for substep in Car.SUBSTEPS:
					car._drivetrain(1.0 / (120.0 * Car.SUBSTEPS))
			_expect(car.hold and car.gear == 1 and car.shift_timer == 0.0, "Finished car must stay held, never select reverse")
			_expect(car.throttle == 0.0 and car.brake == 1.0 and car.handbrake == 0.0, "Finish must use deterministic stopping inputs")
			for wheel in car.wheels:
				_expect(wheel.omega == 0.0, "Held drivetrain must stop wheels without driving backwards")
			_expect(not car._teleport and car.global_transform == old_transform and car.linear_velocity == old_velocity, "Finish must not teleport or directly overwrite body motion")
	# The unchanged countdown still holds; releasing into a live stage must not.
	player.finished = false
	game.set("phase", "countdown")
	game.call("_drive", player, 1.0 / 120.0)
	_expect(car.hold, "Countdown hold changed")
	game.set("phase", "racing")
	game.call("_drive", player, 1.0 / 120.0)
	_expect(not car.hold and driver.saw_released_hold, "Unfinished driving must release the hold before the driver runs")
	car.free()
	game.set("stage", null)
	stage.free()


func _expect(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition
