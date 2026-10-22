// Linear coverage with fixed geometry. Uniforms are paired by GrassField.
// World-coherent phase bends the radial boundary, but never expands support.
uniform float coverage_in_end = 0.0;
uniform float coverage_out_begin = 30.0;
varying flat float coverage_seed;

float grass_transition(float begin, float end, float d, float phase) {
	float t = clamp((d - begin) / max(end - begin, 0.001), 0.0, 1.0);
	// phase is in [-0.2, 0.2]; dt'/dt >= 0.2. Endpoints stay exact.
	t += phase * 4.0 * t * (1.0 - t);
	return t * t * (3.0 - 2.0 * t);
}

float grass_ring_coverage(vec2 xz, float d, float inner, float radius) {
	float phase = (vegetation_noise(xz / 6.0 + 47.0) - 0.5) * 0.4;
	float entering = inner > 0.0 ? grass_transition(inner - 4.0, coverage_in_end, d, phase) : 1.0;
	float leaving = 1.0 - grass_transition(coverage_out_begin, radius, d, phase);
	return entering * leaving;
}

float grass_coverage_sample(vec2 uv, float seed) {
	// A fixed material-space mask follows each world-rooted blade/card.
	// No TIME or screen-pixel phase: camera motion cannot move the pattern
	// over the surface. Minification aliasing still requires a motion gate.
	vec2 p = floor(uv * vec2(16.0, 24.0)) + vec2(seed * 31.0, seed * 47.0);
	vec3 h = fract(vec3(p.x, p.y, p.x) * 0.1031);
	h += dot(h, h.yzx + 33.33);
	return fract((h.x + h.y) * h.z);
}
