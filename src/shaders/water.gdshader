shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_disabled, specular_schlick_ggx;
// A forest stream: peaty brown water, clear in the shallows and dark where
// deep, ripples flowing along UV.y, foam where it meets the banks and rocks.
#include "res://src/shaders/canopy.gdshaderinc"

uniform sampler2D depth_tex : hint_depth_texture, filter_linear;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform vec3 shallow : source_color = vec3(0.42, 0.36, 0.24);
uniform vec3 deep : source_color = vec3(0.07, 0.07, 0.05);
uniform float flow = 0.6;

varying vec3 world;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}

float waves(vec2 p) {
	return vnoise(p) * 0.5 + vnoise(p * 2.3 + 4.0) * 0.3 + vnoise(p * 5.1 - 2.0) * 0.2;
}

void vertex() {
	world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// Ripples carried downstream.
	vec2 p = vec2(UV.x * 6.0, UV.y * 0.9 - TIME * flow);
	vec2 q = vec2(UV.x * 11.0 + 3.0, UV.y * 1.7 - TIME * flow * 1.4);
	float e = 0.05;
	float h = waves(p) + waves(q) * 0.5;
	float hx = waves(p + vec2(e, 0.0)) + waves(q + vec2(e, 0.0)) * 0.5;
	float hy = waves(p + vec2(0.0, e)) + waves(q + vec2(0.0, e)) * 0.5;
	vec3 n = normalize(vec3((h - hx) * 1.6, 1.0, (h - hy) * 1.6));
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
	// How much water lies between the surface and the bed behind it.
	float z = texture(depth_tex, SCREEN_UV).r;
	vec4 ndc = vec4(SCREEN_UV * 2.0 - 1.0, z, 1.0);
	vec4 bed = INV_PROJECTION_MATRIX * ndc;
	bed.xyz /= bed.w;
	float thick = clamp(-bed.z - (-VERTEX.z), 0.0, 10.0);
	float murk = 1.0 - exp(-thick * 1.8);
	vec2 bend = (n.xz) * 0.02 * clamp(thick, 0.0, 1.0);
	vec3 under = textureLod(screen_tex, SCREEN_UV + bend, 0.0).rgb;
	vec3 col = mix(under * shallow * 1.6, deep * (1.0 - canopy_shade(world) * 0.5), murk);
	// Foam at the edges and in the shallows.
	float foam = (1.0 - smoothstep(0.0, 0.25, thick)) * smoothstep(0.45, 0.75, vnoise(world.xz * 3.0 + TIME * 0.3));
	col = mix(col, vec3(0.85, 0.85, 0.8), foam * 0.7);
	ALBEDO = vec3(0.0);
	EMISSION = col;
	ROUGHNESS = 0.04;
	SPECULAR = 0.5;
	METALLIC = 0.0;
	ALPHA = clamp(0.35 + murk * 0.65 + foam * 0.3, 0.0, 1.0) * smoothstep(0.0, 0.06, thick);
}
