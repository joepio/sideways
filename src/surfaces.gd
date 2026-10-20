class_name Surfaces
## Grip per surface. A tyre's force curve is a Pacejka "magic formula" in a
## normalised slip (1.0 is the peak), so each surface sets where the peak sits
## (kappa_peak, alpha_peak), how much grip it has (mu) and how much is left
## when the tyre slides (shape: higher C drops off more after the peak).
## Loose surfaces peak late and keep most of their grip while sliding, which
## is what lets a rally car be driven sideways.

enum { GRAVEL, LOOSE, GRASS, DIRT }

const TABLE := {
	GRAVEL: {"name": "gravel", "mu": 0.86, "kappa_peak": 0.16, "alpha_peak": 0.20, "C": 1.45, "rolling": 0.022, "drag": 0.0},
	LOOSE: {"name": "loose", "mu": 0.72, "kappa_peak": 0.20, "alpha_peak": 0.24, "C": 1.35, "rolling": 0.035, "drag": 0.0},
	GRASS: {"name": "grass", "mu": 0.58, "kappa_peak": 0.14, "alpha_peak": 0.18, "C": 1.55, "rolling": 0.06, "drag": 120.0},
	DIRT: {"name": "dirt", "mu": 0.66, "kappa_peak": 0.18, "alpha_peak": 0.22, "C": 1.4, "rolling": 0.08, "drag": 200.0},
}


static func get_surface(id: int) -> Dictionary:
	return TABLE.get(id, TABLE[GRAVEL])


## Normalised magic formula: 0 at s = 0, 1 at s = 1 (the peak), falling to
## sin(C * PI / 2) when the tyre slides far past the peak.
static func curve(s: float, c: float) -> float:
	var b := tan(PI / (2.0 * c))
	return sin(c * atan(b * s))
