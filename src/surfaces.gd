class_name Surfaces
## Grip per surface. A tyre's force curve is a Pacejka "magic formula" in a
## normalised slip (1.0 is the peak), so each surface sets where the peak sits
## (kappa_peak, alpha_peak), how much grip it has (mu) and how much is left
## when the tyre slides (shape: higher C drops off more after the peak).
## Loose surfaces peak late and keep most of their grip while sliding, which
## is what lets a rally car be driven sideways. Tuned to the grip a pad
## player can hold: a playtest found the real-world values near undrivable.

enum { GRAVEL, LOOSE, GRASS, DIRT, WATER }

const TABLE := {
	GRAVEL: {"name": "gravel", "mu": 1.0, "kappa_peak": 0.16, "alpha_peak": 0.19, "C": 1.3, "rolling": 0.022, "drag": 0.0},
	LOOSE: {"name": "loose", "mu": 0.86, "kappa_peak": 0.20, "alpha_peak": 0.22, "C": 1.25, "rolling": 0.035, "drag": 0.0},
	GRASS: {"name": "grass", "mu": 0.7, "kappa_peak": 0.14, "alpha_peak": 0.18, "C": 1.4, "rolling": 0.06, "drag": 120.0},
	DIRT: {"name": "dirt", "mu": 0.8, "kappa_peak": 0.18, "alpha_peak": 0.21, "C": 1.3, "rolling": 0.08, "drag": 200.0},
	# A ford: wet stones under a hand of water. The water itself pushes back
	# on the car (Car.water_at), this is only the tyres.
	WATER: {"name": "water", "mu": 0.62, "kappa_peak": 0.14, "alpha_peak": 0.18, "C": 1.4, "rolling": 0.05, "drag": 0.0},
}


static func get_surface(id: int) -> Dictionary:
	return TABLE.get(id, TABLE[GRAVEL])


## Normalised magic formula: 0 at s = 0, 1 at s = 1 (the peak), falling to
## sin(C * PI / 2) when the tyre slides far past the peak.
static func curve(s: float, c: float) -> float:
	var b := tan(PI / (2.0 * c))
	return sin(c * atan(b * s))
