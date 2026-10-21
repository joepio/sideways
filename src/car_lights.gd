class_name CarLights
extends Node3D
## Headlights and brake lights that light the world: two spot lights down
## the road (the rally pods, so brighter when the weather is dark) and a red
## glow behind the car while braking. No shadows: cheap enough for a full
## grid in split screen.

static var headlight_energy := 1.0 ## set by the weather

var car: Car
var _heads: Array[SpotLight3D] = []
var _brake: OmniLight3D


static func attach(car: Car) -> void:
	if not car.spec.has("model"):
		return
	var l := CarLights.new()
	l.car = car
	l.name = "Lights"
	car.add_child(l)
	var aabb := CarModel.body_aabb(car)
	var y := lerpf(aabb.position.y, aabb.end.y, 0.32)
	for side in [-1.0, 1.0]:
		var s := SpotLight3D.new()
		s.position = Vector3(side * aabb.size.x * 0.3, y, aabb.position.z + 0.05)
		# Aimed down the road, a touch low so the beam lands 25 m ahead.
		s.rotation = Vector3(deg_to_rad(-3.0), side * deg_to_rad(-2.0), 0.0)
		s.spot_range = 70.0
		s.spot_angle = 24.0
		s.spot_angle_attenuation = 1.6
		s.spot_attenuation = 0.6
		s.light_color = Color(1.0, 0.95, 0.85)
		s.shadow_enabled = false
		s.light_specular = 0.3
		s.distance_fade_enabled = true
		s.distance_fade_begin = 120.0
		s.distance_fade_length = 30.0
		l.add_child(s)
		l._heads.append(s)
	l._brake = OmniLight3D.new()
	l._brake.position = Vector3(0.0, y, aabb.end.z + 0.25)
	l._brake.omni_range = 4.0
	l._brake.light_color = Color(1.0, 0.08, 0.04)
	l._brake.light_energy = 0.0
	l._brake.distance_fade_enabled = true
	l._brake.distance_fade_begin = 60.0
	l._brake.distance_fade_length = 20.0
	l.add_child(l._brake)


func _process(_delta: float) -> void:
	if not is_instance_valid(car):
		return
	for s in _heads:
		s.light_energy = headlight_energy * 6.0
	_brake.light_energy = 1.5 * car.brake if car.brake > 0.05 else 0.0
