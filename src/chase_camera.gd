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


func _ready() -> void:
	# The camera follows the car's interpolated transform every frame itself;
	# interpolating the camera again would lag it a tick behind the car and
	# make the car shake on screen.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	near = 0.08
	far = 1400.0


func snap() -> void:
	_snap = true


func _process(delta: float) -> void:
	if car == null or not is_instance_valid(car):
		return
	var vp := get_viewport()
	var aspect := float(vp.size.x) / maxf(1.0, float(vp.size.y))
	# Keep the horizontal view about the same on wide split screens.
	keep_aspect = Camera3D.KEEP_WIDTH if aspect > 2.0 else Camera3D.KEEP_HEIGHT
	var xf := car.get_global_transform_interpolated()
	var fwd := -xf.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 0.1 else _heading
	match mode:
		BONNET:
			fov = 92.0 if keep_aspect == Camera3D.KEEP_WIDTH else 62.0
			global_transform = xf * Transform3D(Basis(Vector3.RIGHT, deg_to_rad(-3.0)), Vector3(0.0, 0.98, -0.55))
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
	var dist := 4.7 if mode == CHASE else 6.6
	var height := 1.55 if mode == CHASE else 2.15
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
		# Small steps keep the spring stable on a long frame.
		var left := delta
		while left > 0.0:
			var h := minf(left, 1.0 / 120.0)
			_vel += ((target - _pos) * k - _vel * c) * h
			_pos += _vel * h
			left -= h
		_pos.y = lerpf(_pos.y, target.y, clampf(delta * 6.0, 0.0, 1.0))
	global_position = _pos
	look_at(xf.origin + Vector3.UP * 0.85 + _heading * 2.5)
