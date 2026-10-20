class_name Car
extends RigidBody3D
## A rally car simulated the way sim-lite rally games do it: the body is a
## Jolt rigid body, and everything that touches the road is ours.
##
## Per wheel: a ray finds the ground, a spring, damper, bump stop and anti-roll
## bar give the load, and a tyre turns slip into force with a Pacejka curve per
## surface (combined slip, so braking or spinning a wheel costs side grip).
## Slip is a state with a relaxation length, which keeps the tyre stable at
## standstill and gives the slight lag real tyres have.
##
## Drivetrain: engine torque curve and engine braking, an automatic clutch,
## a sequential six-speed with shift time and throttle cut, a centre coupling
## the handbrake opens (as on a real rally car), and plated limited-slip diffs
## front and rear. The wheels, engine and couplings run four substeps per
## physics tick; couplings are solved implicitly, so a locked clutch or diff is
## stiff without blowing up.

const SUBSTEPS := 4
const V_LOW := 1.2 ## m/s: slip stays finite at standstill
const RELAX := 0.25 ## m: tyre relaxation length
const RPM := 60.0 / TAU

class Wheel:
	var anchor: Vector3 ## local wheel centre at full droop
	var axle := 0 ## 0 front, 1 rear
	var side := 1.0 ## -1 left, +1 right
	var radius := 0.33
	var inertia := 1.0
	var omega := 0.0
	var spin := 0.0
	var steer := 0.0
	var compression := 0.0
	var last_compression := 0.0
	var load := 0.0
	var kappa := 0.0
	var tan_alpha := 0.0
	var contact := false
	var point := Vector3.ZERO
	var normal := Vector3.UP
	var surface := 0
	var fx := 0.0
	var fy := 0.0
	var vx := 0.0
	var vy := 0.0
	var wf := Vector3.FORWARD
	var wr := Vector3.RIGHT
	var slide := 0.0 ## 0..1, how far past the grip peak: for sound, dust and marks
	var node: Node3D

# Driver inputs, set every tick by a Driver.
var throttle := 0.0
var brake := 0.0
var steer_input := 0.0
var handbrake := 0.0
var manual := false
var steer_assist := true
var hold := false ## on the start line: in first, clutch in, brakes on; the throttle revs

# State the HUD, audio and AI read.
var spec: Dictionary
var wheels: Array[Wheel] = []
var gear := 1 ## -1 reverse, 1..6
var engine_omega := 100.0
var shift_timer := 0.0
var shift_target := 1
var speed := 0.0 ## m/s along the car
var on_ground := 0 ## wheels touching
var surface_at := Callable() ## (point: Vector3) -> int for road colliders
var grip_scale := 1.0
var stats := {"shifts": 0, "air_time": 0.0, "max_slip_angle": 0.0}

var _reverse_hold := 0.0
var _shift_request := 0
var _teleport := false
var _teleport_to := Transform3D.IDENTITY
var _ray := PhysicsRayQueryParameters3D.new()
var _brake_split := [1.0, 1.0]
var _engine_torque := 0.0


func setup(car_id: String) -> void:
	spec = CarSpec.get_car(car_id)
	mass = spec.mass
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = spec.cg
	inertia = spec.inertia
	can_sleep = false
	continuous_cd = true
	custom_integrator = false
	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	linear_damp = 0.0
	angular_damp = 0.05
	var pm := PhysicsMaterial.new()
	pm.friction = 0.45
	pm.bounce = 0.05
	physics_material_override = pm
	var half_wb: float = spec.wheelbase * 0.5
	var half_tr: float = spec.track * 0.5
	wheels.clear()
	for axle in 2:
		for side in [-1.0, 1.0]:
			var w := Wheel.new()
			w.axle = axle
			w.side = side
			w.radius = spec.wheel_radius
			w.inertia = spec.wheel_inertia
			w.anchor = Vector3(side * half_tr, spec.droop_y, -half_wb if axle == 0 else half_wb)
			wheels.append(w)
	engine_omega = spec.idle_rpm / RPM
	_ray.exclude = [get_rid()]
	_ray.collision_mask = 1


## Puts the car down at `xf` at rest, as soon as the physics thread can.
func teleport(xf: Transform3D) -> void:
	_teleport = true
	_teleport_to = xf
	global_transform = xf
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	for w in wheels:
		w.omega = 0.0
		w.kappa = 0.0
		w.tan_alpha = 0.0
	gear = 1
	shift_timer = 0.0
	reset_physics_interpolation()


func request_shift(direction: int) -> void:
	_shift_request = direction


func rpm() -> float:
	return engine_omega * RPM


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if _teleport:
		_teleport = false
		state.transform = _teleport_to
		state.linear_velocity = Vector3.ZERO
		state.angular_velocity = Vector3.ZERO
		return
	var dt := state.step
	var xf := state.transform
	var up := xf.basis.y
	var fwd := -xf.basis.z
	var com := xf * center_of_mass
	var v := state.linear_velocity
	var av := state.angular_velocity
	speed = v.dot(fwd)
	_steering(dt, v, xf.basis)
	_gearbox(dt)
	_suspension(state, xf, dt)

	# Contact frames: the body's velocity holds still over the substeps.
	for w in wheels:
		if not w.contact:
			continue
		var wf := fwd.rotated(up, w.steer)
		wf = (wf - w.normal * wf.dot(w.normal)).normalized()
		var wr := wf.cross(w.normal)
		var vp := v + av.cross(w.point - com)
		w.vx = vp.dot(wf)
		w.vy = vp.dot(wr)
		w.wf = wf
		w.wr = wr

	var h := dt / SUBSTEPS
	var sum_fx: Array[float] = [0.0, 0.0, 0.0, 0.0]
	var sum_fy: Array[float] = [0.0, 0.0, 0.0, 0.0]
	for _s in SUBSTEPS:
		for i in 4:
			_tyre(wheels[i])
			sum_fx[i] += wheels[i].fx
			sum_fy[i] += wheels[i].fy
		_drivetrain(h)
		for w in wheels:
			var denom := absf(w.vx) + V_LOW
			if w.contact:
				w.kappa += ((w.omega * w.radius - w.vx) - denom * w.kappa) * h / RELAX
				w.tan_alpha += (w.vy - denom * w.tan_alpha) * h / RELAX
			else:
				w.kappa = move_toward(w.kappa, 0.0, h * 8.0)
				w.tan_alpha = move_toward(w.tan_alpha, 0.0, h * 8.0)

	on_ground = 0
	for i in 4:
		var w := wheels[i]
		w.spin = fposmod(w.spin + w.omega * dt, TAU)
		if not w.contact:
			w.slide = move_toward(w.slide, 0.0, dt * 4.0)
			continue
		on_ground += 1
		var f: Vector3 = w.wf * (sum_fx[i] / SUBSTEPS) + w.wr * (sum_fy[i] / SUBSTEPS)
		state.apply_force(f, w.point - xf.origin)
		var surf := Surfaces.get_surface(w.surface)
		var s := Vector2(w.kappa / surf.kappa_peak, w.tan_alpha / surf.alpha_peak).length()
		w.slide = clampf((s - 0.8) / 2.0, 0.0, 1.0)
		# Grass and dirt drag at the car a little, like long grass does.
		state.apply_force(-v.normalized() * surf.drag * minf(v.length(), 10.0) * 0.1 * w.load / 3000.0, w.point - xf.origin)
	if on_ground == 0:
		stats.air_time += dt
	# Air.
	var air: float = spec.drag
	state.apply_central_force(-v * v.length() * air - up * spec.downforce * v.length_squared())
	if v.length() > 5.0 and on_ground > 0:
		var slip_angle := absf(atan2(v.dot(xf.basis.x), absf(speed)))
		stats.max_slip_angle = maxf(stats.max_slip_angle, rad_to_deg(slip_angle))


func _suspension(state: PhysicsDirectBodyState3D, xf: Transform3D, dt: float) -> void:
	var space := state.get_space_state()
	var up := xf.basis.y
	var travel: float = spec.travel
	for w in wheels:
		var origin := xf * (w.anchor + Vector3.UP * travel)
		var reach := travel + w.radius
		_ray.from = origin
		_ray.to = origin - up * reach
		var hit := space.intersect_ray(_ray)
		w.last_compression = w.compression
		if hit.is_empty():
			w.contact = false
			w.compression = 0.0
			w.load = 0.0
			continue
		w.contact = true
		w.compression = clampf(reach - origin.distance_to(hit.position), 0.0, travel)
		w.point = hit.position
		w.normal = hit.normal
		w.surface = _surface(hit)
	for axle in 2:
		var l := wheels[axle * 2]
		var r := wheels[axle * 2 + 1]
		var roll: float = (l.compression - r.compression) * spec.arb[axle]
		for w in [l, r]:
			if not w.contact:
				continue
			var rate := clampf((w.compression - w.last_compression) / dt, -4.0, 4.0)
			var damper: float = (spec.bump[axle] if rate > 0.0 else spec.rebound[axle]) * rate
			var force: float = spec.spring[axle] * w.compression + damper + (roll if w == l else -roll)
			var stop := travel * 0.88
			if w.compression > stop:
				force += (w.compression - stop) * spec.spring[axle] * 14.0
			w.load = clampf(force, 0.0, 24000.0)
			state.apply_force(up * w.load, w.point - xf.origin)


func _surface(hit: Dictionary) -> int:
	var c: Object = hit.collider
	if c.has_meta("road") and surface_at.is_valid():
		return surface_at.call(hit.position)
	return int(c.get_meta("surface", Surfaces.DIRT))


## Turns slip into force. Combined slip: the normalised slip vector picks
## the direction, its length picks the point on the curve.
func _tyre(w: Wheel) -> void:
	w.fx = 0.0
	w.fy = 0.0
	if not w.contact or w.load <= 0.0:
		return
	var surf := Surfaces.get_surface(w.surface)
	var kn: float = w.kappa / surf.kappa_peak
	var an: float = w.tan_alpha / surf.alpha_peak
	var s := sqrt(kn * kn + an * an)
	if s < 1e-6:
		return
	# Tyres lose a little grip per kg as the load rises.
	var mu: float = surf.mu * grip_scale * clampf(1.0 - 0.07 * (w.load / 3000.0 - 1.0), 0.75, 1.1)
	var f: float = mu * w.load * Surfaces.curve(s, surf.C)
	w.fx = f * kn / s * 1.04
	w.fy = -f * an / s


func _drivetrain(h: float) -> void:
	# Tyres push back on the wheels.
	for w in wheels:
		w.omega += -w.fx * w.radius * h / w.inertia
	# Engine.
	var cut: bool = shift_timer > 0.0 or rpm() > spec.limit_rpm
	var t := throttle
	if gear < 0 and not manual:
		t = brake # automatic: in reverse the brake pedal drives, as in most racing games
	var idle_assist: float = clampf((spec.idle_rpm - rpm()) / 250.0, 0.0, 0.35)
	t = maxf(t, idle_assist)
	if cut:
		t = 0.0
	_engine_torque = _curve(rpm()) * t - (spec.friction[0] + spec.friction[1] * rpm()) * (1.0 - t)
	engine_omega += _engine_torque * h / spec.engine_inertia
	engine_omega = maxf(engine_omega, 300.0 / RPM)

	# Shares of the drive per wheel. The handbrake opens the centre, so all
	# drive goes to the front while it is pulled.
	var shares: Array[float] = [spec.drive[0] * 0.5, spec.drive[0] * 0.5, spec.drive[1] * 0.5, spec.drive[1] * 0.5]
	var centre_open: bool = handbrake > 0.1
	if centre_open:
		shares = [0.5, 0.5, 0.0, 0.0]
	var axle_torque := [0.0, 0.0]
	if shift_timer <= 0.0 and not hold:
		var g: float = spec.gears[0] * -1.0 if gear < 0 else spec.gears[gear]
		g *= spec.final
		var w_t := 0.0
		var k := 0.0
		for i in 4:
			w_t += shares[i] * wheels[i].omega
			k += shares[i] * shares[i] / wheels[i].inertia
		k *= g * g
		var slip := engine_omega - g * w_t
		# Automatic clutch: opens near idle so the engine never stalls.
		# Driven by the wheels as well, so a rolling car pulls the engine up
		# (engine braking, and no coasting at idle after a lock-up).
		var engage: float = maxf(smoothstep(spec.idle_rpm + 150.0, 3600.0, rpm()), smoothstep(spec.idle_rpm + 300.0, 2600.0, absf(g * w_t) * RPM))
		if absf(slip) < 30.0 and rpm() > spec.idle_rpm + 600.0:
			engage = 1.0
		var cap: float = spec.clutch * engage
		var tau: float = clampf(slip / (h * (1.0 / spec.engine_inertia + k)), -cap, cap)
		engine_omega -= tau * h / spec.engine_inertia
		for i in 4:
			var wt: float = shares[i] * tau * g
			wheels[i].omega += wt * h / wheels[i].inertia
			axle_torque[i / 2] += absf(wt)
	# Centre coupling.
	if not centre_open:
		var front := (wheels[0].omega + wheels[1].omega) * 0.5
		var rear := (wheels[2].omega + wheels[3].omega) * 0.5
		var i_w: float = wheels[0].inertia
		var tau_c: float = clampf((front - rear) * i_w / h, -spec.centre_lock, spec.centre_lock)
		for i in 4:
			wheels[i].omega += (-0.5 if i < 2 else 0.5) * tau_c * h / wheels[i].inertia
	# Plated diffs: lock grows with the torque through them.
	for axle in 2:
		var l := wheels[axle * 2]
		var r := wheels[axle * 2 + 1]
		var cap_d: float = spec.diff_preload[axle] + spec.diff_ramp[axle] * axle_torque[axle]
		var tau_d: float = clampf((l.omega - r.omega) / (h * (1.0 / l.inertia + 1.0 / r.inertia)), -cap_d, cap_d)
		l.omega -= tau_d * h / l.inertia
		r.omega += tau_d * h / r.inertia
	# Brakes, handbrake and rolling resistance: friction that can stop a wheel
	# but never spin it backwards.
	var foot := brake if gear > 0 or manual else throttle
	if hold:
		foot = 1.0
	for w in wheels:
		var t_b: float = foot * spec.brake[w.axle]
		if w.axle == 1:
			t_b += handbrake * spec.handbrake
		if w.contact:
			t_b += Surfaces.get_surface(w.surface).rolling * w.load * w.radius
		var stop: float = t_b * h / w.inertia
		w.omega = 0.0 if absf(w.omega) <= stop else w.omega - signf(w.omega) * stop


func _curve(r: float) -> float:
	var pts: Array = spec.torque
	if r <= pts[0][0]:
		return pts[0][1]
	for i in range(1, pts.size()):
		if r <= pts[i][0]:
			var a: Array = pts[i - 1]
			var b: Array = pts[i]
			return lerpf(a[1], b[1], (r - a[0]) / (b[0] - a[0]))
	return 0.0


func _steering(dt: float, v: Vector3, basis: Basis) -> void:
	var lock: float = spec.max_steer
	var ground_speed := v.length()
	if steer_assist and ground_speed > 6.0:
		# On a pad, limit the lock at speed to what the tyres can use, but
		# always leave room to counter-steer a slide.
		var beta := absf(atan2(v.dot(basis.x), absf(v.dot(-basis.z))))
		var useful := beta + deg_to_rad(9.0)
		lock = lerpf(lock, minf(lock, useful), clampf((ground_speed - 6.0) / 22.0, 0.0, 1.0))
	var target := -steer_input * lock
	var current := wheels[0].steer
	var rate := 3.2 if absf(target) > absf(current) else 4.5
	var next := move_toward(current, target, rate * dt)
	for w in wheels:
		w.steer = next if w.axle == 0 else 0.0


func _gearbox(dt: float) -> void:
	if hold:
		gear = 1
		shift_timer = 0.0
		_shift_request = 0
		return
	if shift_timer > 0.0:
		shift_timer -= dt
		if shift_timer <= 0.0:
			gear = shift_target
		return
	var top: int = spec.gears.size() - 1
	if _shift_request != 0:
		var want := gear + _shift_request
		_shift_request = 0
		if gear == 1 and want == 0:
			want = -1 if speed < 2.5 else 1
		elif gear == -1 and want == 0:
			want = 1
		want = clampi(want, -1, top)
		if want != gear and (want < 0 or want < gear and _rpm_in(want) < spec.limit_rpm + 200.0 or want > gear):
			_shift(want)
		return
	if manual:
		return
	# Automatic: up near the limiter, down when it bogs, into reverse when
	# the brake is held at a standstill.
	if gear > 0:
		if brake > 0.5 and throttle < 0.1 and speed < 0.6:
			_reverse_hold += dt
			if _reverse_hold > 0.35:
				_reverse_hold = 0.0
				_shift(-1)
				return
		else:
			_reverse_hold = 0.0
		var slipping := false
		for i in 4:
			if wheels[i].slide > 0.4:
				slipping = true
		if gear < top and rpm() > spec.upshift_rpm and throttle > 0.2 and on_ground >= 2 and not (slipping and speed < 12.0):
			_shift(gear + 1)
		elif gear > 1:
			var down: float = spec.downshift_rpm + 1400.0 * brake - 900.0 * (1.0 - throttle)
			if rpm() < down and _rpm_in(gear - 1) < spec.upshift_rpm - 500.0:
				_shift(gear - 1)
	elif gear < 0 and throttle > 0.4 and speed > -1.0:
		_shift(1)


func _rpm_in(g: int) -> float:
	var ratio: float = (spec.gears[0] if g < 0 else spec.gears[g]) * spec.final
	var w_t := 0.0
	for w in wheels:
		w_t += absf(w.omega) * 0.25
	# Locked wheels say nothing about speed: use the car's.
	w_t = maxf(w_t, absf(speed) / spec.wheel_radius)
	return w_t * ratio * RPM


func _shift(to: int) -> void:
	shift_target = to
	shift_timer = spec.shift_time
	stats.shifts += 1


func _physics_process(_delta: float) -> void:
	# Wheels drawn where the suspension put them; physics interpolation smooths it.
	for w in wheels:
		if w.node == null:
			continue
		w.node.position = w.anchor + Vector3.UP * w.compression
		w.node.basis = Basis(Vector3.UP, w.steer) * Basis(Vector3.RIGHT, -w.spin)
