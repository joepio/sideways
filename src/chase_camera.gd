class_name ChaseCamera
extends Camera3D
## Follows one car. Chase: behind and above, swinging round slowly, so a
## slide shows as the car turning in the frame. Bonnet: on the hood.
## Far chase: further back. Side and top are for screenshots.

enum { CHASE, BONNET, FAR, SIDE, TOP }

var car: Car
var mode := CHASE
var _heading := Vector3.FORWARD
var _pos := Vector3.ZERO
var _vel := Vector3.ZERO
var _snap := true

# Hold a direction to look around; release to return to the driving view.
# The stick selects a viewing direction: up is rear, down is front,
# right shows the left flank. Bonnet stays attached to the car.
const LOOK_DEADZONE := 0.15
const LOOK_RESPONSE := 10.0
const LOOK_RETURN := 6.0
var look_input := Vector2.ZERO
var _look_angles := Vector2.ZERO # yaw, elevation offset in radians

# Bounded current-Jolt prototype: static-world queries after synchronous physics.
const WORLD_RADIUS := 0.25
const WORLD_RELEASE_SPEED := 6.0
const WORLD_ANCHOR_RISES: Array[float] = [0.0, 0.6, 1.5, 3.0]
var _world_shape := SphereShape3D.new()
var _world_query := PhysicsShapeQueryParameters3D.new()
var _world_distance := -1.0
# Counters make exceptional fallback and intervention visible to the trial.
var _world_unresolved := 0
var _world_clamped_frames := 0
var _world_anchor_lift_frames := 0


func _ready() -> void:
	# The camera follows the car's interpolated transform every frame itself;
	# interpolating the camera again would lag it a tick behind the car and
	# make the car shake on screen.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	near = 0.08
	far = 1400.0
	# This render-time query design is only supported by the audited configuration.
	if bool(ProjectSettings.get_setting_with_override("physics/3d/run_on_separate_thread")) or str(ProjectSettings.get_setting_with_override("physics/3d/physics_engine")) != "Jolt Physics":
		push_error("Camera world sweep requires the reviewed main-thread Jolt configuration")
		set_process(false)
		return
	_world_shape.radius = WORLD_RADIUS
	_world_query.shape = _world_shape
	_world_query.collision_mask = 1 # StageBuilder static bodies; cars use2, ghosts4.
	_world_query.collide_with_bodies = true
	_world_query.collide_with_areas = false
	_world_query.margin = 0.02


func snap() -> void:
	_snap = true
	look_input = Vector2.ZERO
	_look_angles = Vector2.ZERO


func _process(delta: float) -> void:
	if car == null or not is_instance_valid(car):
		return
	_advance_look(delta)
	var vp := get_viewport()
	var aspect := float(vp.size.x) / maxf(1.0, float(vp.size.y))
	# Keep the horizontal view about the same on wide split screens.
	keep_aspect = Camera3D.KEEP_WIDTH if aspect > 2.0 else Camera3D.KEEP_HEIGHT
	var xf := car.get_global_transform_interpolated()
	var fwd := -xf.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 0.1 else _heading
	if _snap or (mode != CHASE and mode != FAR):
		_world_distance = -1.0
	match mode:
		BONNET:
			fov = 92.0 if keep_aspect == Camera3D.KEEP_WIDTH else 62.0
			global_transform = xf * Transform3D(Basis(Vector3.RIGHT, deg_to_rad(-3.0)), CarModel.hood_eye(car))
			_snap = true
			return
		SIDE:
			fov = 40.0
			keep_aspect = Camera3D.KEEP_HEIGHT
			var side := xf.basis.x
			side.y = 0.0
			global_position = xf.origin + side.normalized() * 9.0 + Vector3.UP * 1.6 - fwd * 1.0
			look_at(xf.origin + Vector3.UP * 0.5)
			return
		TOP:
			fov = 50.0
			keep_aspect = Camera3D.KEEP_HEIGHT
			global_position = xf.origin + Vector3.UP * 36.0 - fwd * 24.0
			look_at(xf.origin + fwd * 8.0)
			return
	# High enough to look over the car at the road ahead (a playtest found
	# the car hid too much of it).
	var dist := 5.2 if mode == CHASE else 7.2
	var height := 2.05 if mode == CHASE else 2.9
	fov = 90.0 if keep_aspect == Camera3D.KEEP_WIDTH else 64.0
	if _snap:
		_heading = fwd
	else:
		# Swing towards the car's heading; faster when the gap is large.
		var gap := _heading.angle_to(fwd)
		var rate := 2.4 + gap * 3.0
		_heading = _heading.slerp(fwd, clampf(rate * delta, 0.0, 1.0)).normalized()
	var target := xf.origin - _heading * dist + Vector3.UP * height
	if _snap:
		_pos = target
		_vel = Vector3.ZERO
		_snap = false
	else:
		# Critically damped spring, stiffer vertically so crests don't drop it under the road.
		var k := 60.0
		var c := 2.0 * sqrt(k)
		# Follow horizontal car motion without adding speed-dependent spring lag.
		# Keep the existing vertical response over crests and landings.
		var follow_velocity := car.linear_velocity
		follow_velocity.y = 0.0
		# Small steps keep the spring stable on a long frame.
		var left := delta
		while left > 0.0:
			var h := minf(left, 1.0 / 120.0)
			_vel += ((target - _pos) * k - (_vel - follow_velocity) * c) * h
			_pos += _vel * h
			left -= h
		_pos.y = lerpf(_pos.y, target.y, clampf(delta * 6.0, 0.0, 1.0))
	if _look_angles != Vector2.ZERO:
		var pivot := xf.origin + Vector3.UP * 0.9
		var wanted := _orbit_eye(pivot, _pos)
		# Bring the focus onto the car as the driver looks to its sides/front.
		var focus := minf(1.0, maxf(absf(_look_angles.x) / (PI * 0.25), absf(_look_angles.y) / deg_to_rad(15.0)))
		global_position = _world_eye(xf.origin + Vector3.UP * 1.2, wanted, delta)
		look_at(pivot + _heading * (4.0 * (1.0 - focus)))
	else:
		# Exact existing no-input path, including the free spring and world sweep.
		global_position = _world_eye(xf.origin + Vector3.UP * 1.2, _pos, delta)
		look_at(xf.origin + Vector3.UP * 0.9 + _heading * 4.0)


static func look_stick(raw: Vector2) -> Vector2:
	if not raw.is_finite():
		return Vector2.ZERO
	var magnitude := raw.length()
	if magnitude <= LOOK_DEADZONE:
		return Vector2.ZERO
	return raw / magnitude * minf((magnitude - LOOK_DEADZONE) / (1.0 - LOOK_DEADZONE), 1.0)


func _advance_look(delta: float) -> void:
	if mode != CHASE and mode != FAR:
		_look_angles = Vector2.ZERO
		return
	var stick := look_stick(look_input)
	if stick == Vector2.ZERO and _look_angles == Vector2.ZERO:
		return
	# Treat the stick as a direction around the car, not separate yaw/pitch
	# axes. In particular, fully right is 90 degrees, not a front view.
	var wanted := 0.0 if stick == Vector2.ZERO else atan2(-stick.x, -stick.y)
	var rate := LOOK_RETURN if stick == Vector2.ZERO else LOOK_RESPONSE
	_look_angles.x = wrapf(lerp_angle(_look_angles.x, wanted, 1.0 - exp(-rate * maxf(delta, 0.0))), -PI, PI)
	_look_angles.y = 0.0
	if stick == Vector2.ZERO and _look_angles.length_squared() < 0.00000001:
		_look_angles = Vector2.ZERO


func _orbit_eye(pivot: Vector3, free_eye: Vector3) -> Vector3:
	var arm := (free_eye - pivot).rotated(Vector3.UP, _look_angles.x)
	var side := Vector3.UP.cross(arm).normalized()
	if side != Vector3.ZERO:
		arm = arm.rotated(side, -_look_angles.y)
	return pivot + arm


# Only the displayed eye is shortened. The freely damped _pos/_vel, heading,
# look target, physics and controls remain unchanged, including while blocked.
func _world_eye(anchor: Vector3, wanted: Vector3, delta: float) -> Vector3:
	if OS.get_thread_caller_id() != OS.get_main_thread_id():
		return _world_failure("Camera world query called outside the main thread")
	var space := get_world_3d().direct_space_state
	if space == null:
		return _world_failure("Camera world query has no direct space")
	# cast_motion ignores initial overlaps. Check the anchor first; a short,
	# bounded upward search handles a nearby bank/wall without Stage.height.
	var start := anchor
	var anchor_clear := false
	_world_query.motion = Vector3.ZERO
	for rise in WORLD_ANCHOR_RISES:
		start = anchor + Vector3.UP * rise
		_world_query.transform = Transform3D(Basis.IDENTITY, start)
		if space.intersect_shape(_world_query, 1).is_empty():
			anchor_clear = true
			if rise > 0.0:
				_world_anchor_lift_frames += 1
			break
	if not anchor_clear:
		return _world_failure("Camera world sweep has no clear anchor")
	var offset := wanted - start
	var length := offset.length()
	if length <= 0.00001:
		_world_distance = -1.0
		return start
	_world_query.motion = offset
	var fractions := space.cast_motion(_world_query)
	if fractions.size() != 2:
		return _world_failure("Camera world sweep returned no safe fraction")
	var allowed := length if fractions[0] >= 1.0 else maxf(0.0, length * fractions[0] - 0.02)
	if _world_distance < 0.0:
		_world_distance = length
	# Pull in immediately; release by at most6m/s, still bounded by this sweep.
	_world_distance = minf(allowed, _world_distance + maxf(delta, 0.0) * WORLD_RELEASE_SPEED)
	if _world_distance >= length:
		_world_distance = -1.0
		return wanted # Preserve the exact ordinary free-camera position.
	_world_clamped_frames += 1
	return start + offset * (_world_distance / length)


func _world_failure(message: String) -> Vector3:
	_world_unresolved += 1
	if _world_unresolved == 1:
		push_error(message) # A diagnostic run with any unresolved frame must fail.
	# Keep the last displayed eye; do not invent an unverified escape/height clamp.
	return global_position
