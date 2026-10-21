shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, shadows_disabled;
// An exhaust pop: white-blue at the pipe, orange to the flickering tip.
// UV.y runs 0 at the tip to 1 at the pipe on Godot's cylinder.

instance uniform float heat = 1.0;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

void fragment() {
	float base = UV.y;
	float n = hash(floor(vec2(UV.x * 10.0, UV.y * 6.0 + TIME * 40.0)));
	vec3 col = mix(vec3(1.0, 0.35, 0.05), vec3(1.0, 0.8, 0.45), smoothstep(0.4, 0.9, base));
	col = mix(col, vec3(0.6, 0.7, 1.0), smoothstep(0.88, 1.0, base));
	// Rim fades so the cone reads as a soft tongue, not a solid.
	float rim = pow(abs(dot(NORMAL, VIEW)), 1.5);
	ALBEDO = col * (base * 0.8 + 0.2) * (0.7 + 0.5 * n) * rim * heat * 3.0;
}
