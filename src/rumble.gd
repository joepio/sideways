class_name Rumble
## What a driver feels through the pad. The light motor carries the road:
## a crunch that grows with speed and differs per surface (gravel buzzes,
## loose gravel rattles, grass is soft, a ford is heavy). The heavy motor
## carries the car: it stays quiet while the tyres grip and grumbles as they
## slide or spin, and it kicks on bumps and landings.

const TEXTURE := {
	Surfaces.GRAVEL: 0.16,
	Surfaces.LOOSE: 0.24,
	Surfaces.DIRT: 0.12,
	Surfaces.GRASS: 0.07,
	Surfaces.WATER: 0.35,
}

var _rng := RandomNumberGenerator.new() ## own generator: the simulation's stays untouched
var _kick := 0.0
var _airborne := 0.0


## Motor strengths (weak, strong) for this moment, 0..1 each.
func feel(car: Car, dt: float) -> Vector2:
	var speed := absf(car.speed)
	var road := 0.0
	var slide := 0.0
	var spin := 0.0
	var touching := 0
	for w in car.wheels:
		if not w.contact:
			continue
		touching += 1
		road += TEXTURE.get(w.surface, 0.12)
		slide = maxf(slide, w.slide)
		spin = maxf(spin, clampf(absf(w.omega * w.radius - w.vx) / 10.0, 0.0, 1.0))
		var rate := (w.compression - w.last_compression) / maxf(dt, 1e-4)
		if absf(rate) > 0.6:
			_kick = maxf(_kick, clampf((absf(rate) - 0.6) / 2.5, 0.0, 0.7))
	if touching > 0:
		road /= touching
	# A landing after a jump: a thump sized by the time in the air.
	if touching == 0:
		_airborne += dt
	else:
		if _airborne > 0.25:
			_kick = maxf(_kick, clampf(_airborne * 0.8, 0.35, 1.0))
		_airborne = 0.0
	var crunch := road * clampf(speed / 22.0, 0.0, 1.0) * (0.6 + 0.8 * _rng.randf())
	var grip := clampf(slide * 0.55 + spin * 0.35, 0.0, 0.6) * clampf(speed / 6.0, 0.3, 1.0) * (0.75 + 0.5 * _rng.randf())
	var strong := maxf(grip, _kick)
	_kick = move_toward(_kick, 0.0, dt * 6.0)
	return Vector2(clampf(crunch + grip * 0.3, 0.0, 1.0), clampf(strong, 0.0, 1.0))
