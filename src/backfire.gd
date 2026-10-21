class_name Backfire
extends Node3D
## Flames out of the exhaust: a downshift at high revs, or snapping off the
## throttle near the limiter, now and then pops unburnt fuel in the pipe. A
## short glowing cone and an orange flash on the ground behind the car.
## Purely for show, with its own random numbers, so the simulation is the
## same with or without it.

const LIFE := 0.07 ## seconds one pop burns

var car: Car
var _flame: MeshInstance3D
var _light: OmniLight3D
var _rng := RandomNumberGenerator.new()
var _pops := 0 ## still to come in this burst
var _t := 0.0 ## time left of the current pop
var _gap := 0.0 ## until the next pop
var _shifting := false
var _throttle := 0.0


static func attach(car: Car) -> void:
	if not car.spec.has("model"):
		return
	var b := Backfire.new()
	b.car = car
	b.name = "Backfire"
	b._rng.seed = hash(car.get_instance_id())
	var aabb := CarModel.body_aabb(car)
	# Under the rear bumper, off to the right like most rally cars.
	b.position = car.spec.get("exhaust", Vector3(aabb.size.x * 0.27, aabb.position.y + 0.2, aabb.end.z - 0.02))
	car.add_child(b)
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.07
	cone.height = 0.5
	cone.radial_segments = 10
	cone.rings = 2
	b._flame = MeshInstance3D.new()
	b._flame.mesh = cone
	# The cone's base at the pipe, its tip pointing out behind the car.
	b._flame.basis = Basis(Vector3.RIGHT, PI * 0.5)
	b._flame.position = Vector3(0.0, 0.0, 0.25)
	var m := ShaderMaterial.new()
	m.shader = preload("res://src/shaders/flame.gdshader")
	b._flame.material_override = m
	b._flame.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	b._flame.visible = false
	b.add_child(b._flame)
	b._light = OmniLight3D.new()
	b._light.position = Vector3(0.0, 0.05, 0.4)
	b._light.omni_range = 3.5
	b._light.light_color = Color(1.0, 0.5, 0.15)
	b._light.light_energy = 0.0
	b._light.shadow_enabled = false
	b.add_child(b._light)


func _process(delta: float) -> void:
	if not is_instance_valid(car):
		return
	var rpm := car.rpm()
	var shifting := car.shift_timer > 0.0
	if shifting and not _shifting and car.shift_target < car.gear and car.shift_target > 0 and rpm > 4300.0 and _rng.randf() < 0.55:
		_burst()
	elif _throttle > 0.7 and car.throttle < 0.1 and rpm > 5800.0 and _rng.randf() < 0.3:
		_burst()
	_shifting = shifting
	_throttle = car.throttle
	if _t > 0.0:
		_t -= delta
		var k := clampf(_t / LIFE, 0.0, 1.0)
		_flame.scale = Vector3.ONE * (0.6 + 0.6 * k)
		_flame.set_instance_shader_parameter("heat", k)
		_light.light_energy = 2.5 * k
		if _t <= 0.0:
			_flame.visible = false
			_light.light_energy = 0.0
	elif _pops > 0:
		_gap -= delta
		if _gap <= 0.0:
			_pop()


func _burst() -> void:
	_pops = _rng.randi_range(1, 3)
	_gap = 0.0


func _pop() -> void:
	_pops -= 1
	_gap = _rng.randf_range(0.05, 0.14)
	_t = LIFE * _rng.randf_range(0.7, 1.4)
	_flame.visible = true
	_flame.rotation.y = _rng.randf() * TAU
