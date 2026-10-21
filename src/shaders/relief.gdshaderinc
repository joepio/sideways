// Ground relief the 2 m terrain grid is too coarse to carry: hummocks and
// roots on the forest floor and knobbly rock on steep faces. A height in
// metres added on top of the terrain (and under the grass carpet, so the
// grass stands on it). Zero on the road shoulder and from 13 m out, so the
// road, the colliders and the coarse terrain still meet. Only ever adds, so
// tufts and trees planted on the coarse ground sink in rather than float.

float rl_hash(vec2 p) { return fract(sin(dot(p, vec2(269.5, 183.3))) * 43758.5453); }
float rl_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(rl_hash(i), rl_hash(i + vec2(1, 0)), f.x), mix(rl_hash(i + vec2(0, 1)), rl_hash(i + vec2(1, 1)), f.x), f.y);
}

// p: world position on the coarse ground; rd: metres from the road edge;
// up: the coarse ground normal's y.
float relief(vec3 p, float rd, float up) {
	float fade = smoothstep(0.6, 2.5, rd) * (1.0 - smoothstep(9.0, 13.0, rd));
	if (fade <= 0.0) {
		return 0.0;
	}
	// Across a steep face the height changes fastest, so it joins in.
	vec2 q = p.xz + p.yy * vec2(0.7, -0.5);
	float hum = rl_noise(q / 2.2) * 0.65 + rl_noise(q / 1.1 + 7.0) * 0.35;
	float ground = hum * hum * 0.16;
	float r1 = 1.0 - abs(rl_noise(q / 3.0 + vec2(3.0, 9.0)) * 2.0 - 1.0);
	float r2 = 1.0 - abs(rl_noise(q / 1.4 + vec2(13.0, 2.0)) * 2.0 - 1.0);
	float rock = (r1 * r1 * 0.7 + r2 * 0.3) * 0.42;
	return mix(ground, rock, smoothstep(0.82, 0.55, up)) * fade;
}

// The coarse normal tilted by the relief's slope.
vec3 relief_normal(vec3 p, vec3 n, float rd, float h0) {
	const float STEP = 0.3;
	float hx = relief(p + vec3(STEP, 0.0, 0.0), rd, n.y);
	float hz = relief(p + vec3(0.0, 0.0, STEP), rd, n.y);
	return normalize(n / max(n.y, 0.15) - vec3((hx - h0) / STEP, 0.0, (hz - h0) / STEP));
}
