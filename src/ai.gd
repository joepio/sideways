class_name RallyAI
## A bot driver: pure pursuit on the centre line, and a speed plan from the
## curvature ahead (what the tyres can hold, minus a margin, with braking
## distance). `pace` below 1 drives slower and earlier on the brakes.

var stage: Stage
var pace := 0.92
var hint := -1
var stuck := 0.0
var _wobble := 0.0


var plan := PackedFloat32Array()


func _init(s: Stage, p: float) -> void:
	stage = s
	pace = p
	_wobble = randf() * TAU
	# Corner speeds from the radius, then a backward pass for braking.
	var n := s.points.size()
	plan.resize(n)
	var mu := 0.78 * pace
	for i in n:
		var k := 0.0
		for j in range(maxi(0, i - 4), mini(n, i + 5)):
			k = maxf(k, absf(s.curvature[j]))
		plan[i] = minf(sqrt(mu * 9.81 / maxf(k, 1e-4)), 58.0)
	var decel := 6.0 * pace
	for i in range(n - 2, -1, -1):
		plan[i] = minf(plan[i], sqrt(plan[i + 1] * plan[i + 1] + 2.0 * decel * Stage.STEP))


func drive(car: Car, dt: float) -> void:
	var pos := car.global_position
	var loc := stage.locate(pos, hint)
	if loc.index < 0:
		car.throttle = 0.3
		car.steer_input = 0.0
		return
	hint = loc.index
	var v := car.linear_velocity.length()
	var along: float = loc.along
	# Steering: aim at a point ahead, a little inside on corners.
	var look := 7.0 + v * 0.55
	var target := stage.point_at(along + look)
	var k_ahead := stage.curvature_at(along + look)
	var right := Vector3(-stage.dir_at(along + look).z, 0.0, stage.dir_at(along + look).x)
	target -= right * clampf(k_ahead * 60.0, -1.0, 1.0) * stage.width_at(along + look) * 0.35
	var fwd := -car.global_basis.z
	fwd.y = 0.0
	var to := target - pos
	to.y = 0.0
	var angle := fwd.signed_angle_to(to, Vector3.UP) # + is left
	# Counter the slide the car already has.
	var vel := car.linear_velocity
	vel.y = 0.0
	var slip := 0.0
	if v > 4.0:
		slip = fwd.signed_angle_to(vel, Vector3.UP)
	var steer := -(angle * 2.1 + slip * 0.6)
	car.steer_input = clampf(steer, -1.0, 1.0)
	# Speed: from the plan, looked up a little ahead for reaction time.
	var limit := plan[clampi(int((along + v * 0.35) / Stage.STEP), 0, plan.size() - 1)]
	var err := limit - v
	car.throttle = clampf(err * 0.35 + 0.25, 0.0, 1.0) if err > -1.0 else 0.0
	car.brake = clampf(-err * 0.25, 0.0, 1.0) if err < -1.5 else 0.0
	car.handbrake = 1.0 if absf(stage.curvature_at(along + 6.0)) > 1.0 / 20.0 and v > 9.0 and absf(slip) < 0.35 else 0.0
	if v < 1.0 and car.throttle > 0.5:
		stuck += dt
	else:
		stuck = maxf(0.0, stuck - dt)
