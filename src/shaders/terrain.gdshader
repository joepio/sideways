shader_type spatial;
#include "res://src/shaders/canopy.gdshaderinc"
// Finnish forest floor: moss and twigs under the trees, patches of needle
// litter, a grassy verge along the road and bare stony soil at the road edge
// and on steep banks (COLOR.r is the distance from the road edge, 0..14 m
// mapped to 0..1). Each layer is sampled at two scales, the second turned,
// so the tiling doesn't show.

uniform sampler2D moss_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D moss_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D needles_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D needles_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D verge_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D verge_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D ground_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D ground_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;

varying vec3 world_pos;
varying float road_d;
varying float up;
varying vec3 wn;
varying float canopy;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}
float fbm(vec2 p) { return vnoise(p) * 0.55 + vnoise(p * 2.1) * 0.3 + vnoise(p * 4.3) * 0.15; }

const mat2 TURN = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8));

vec3 layer(sampler2D tex, vec2 uv, float scale, float far) {
	vec3 a = texture(tex, uv / scale).rgb;
	vec3 b = texture(tex, TURN * uv / (scale * 4.3)).rgb;
	return mix(a, b, 0.3 + far * 0.4);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	road_d = COLOR.r;
	wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	up = wn.y;
}

void fragment() {
	vec2 uv = world_pos.xz;
	float far = smoothstep(30.0, 140.0, length(world_pos - CAMERA_POSITION_WORLD));
	vec3 moss = layer(moss_albedo, uv, 3.2, far) * vec3(0.78, 0.86, 0.7);
	vec3 needles = layer(needles_albedo, uv, 2.8, far) * vec3(0.72, 0.66, 0.6);
	vec3 verge = layer(verge_albedo, uv, 2.6, far) * vec3(0.72, 0.8, 0.58);
	vec3 ground = layer(ground_albedo, uv, 3.0, far) * vec3(0.85, 0.8, 0.75);
	float m_needles = smoothstep(0.48, 0.62, fbm(uv / 11.0 + 7.0));
	float m_verge = (1.0 - smoothstep(0.25, 0.6, road_d + (fbm(uv / 4.0) - 0.5) * 0.3)) * smoothstep(0.03, 0.1, road_d);
	float m_bare = 1.0 - smoothstep(0.03, 0.12, road_d + (fbm(uv / 2.5) - 0.5) * 0.12);
	m_bare = max(m_bare, smoothstep(0.82, 0.62, up) * 0.8);
	vec3 col = mix(moss, needles, m_needles);
	col = mix(col, verge, m_verge);
	col = mix(col, ground, m_bare);
	// Big soft light and dark patches, as under a broken canopy.
	col *= 0.78 + 0.34 * fbm(uv / 31.0);
	// Rock on cliffs and steep cuts, projected from the side so it doesn't
	// stretch down the face.
	float m_rock = smoothstep(0.72, 0.5, up + (fbm(uv / 3.0) - 0.5) * 0.15);
	vec3 tw = pow(abs(wn), vec3(4.0));
	tw /= tw.x + tw.y + tw.z;
	vec3 rock = (texture(rock_albedo, world_pos.zy / 4.0).rgb * tw.x + texture(rock_albedo, world_pos.xz / 4.0).rgb * tw.y + texture(rock_albedo, world_pos.xy / 4.0).rgb * tw.z) * vec3(0.62, 0.63, 0.62);
	col = mix(col, rock * (0.85 + 0.3 * fbm(world_pos.xy / 9.0 + world_pos.zz / 9.0)), m_rock);
	col *= mix(1.0, 0.7, wetness);
	ALBEDO = col;
	vec3 n = mix(texture(moss_normal, uv / 3.2).rgb, texture(needles_normal, uv / 2.8).rgb, m_needles);
	n = mix(n, texture(verge_normal, uv / 2.6).rgb, m_verge);
	n = mix(n, texture(ground_normal, uv / 3.0).rgb, m_bare);
	n = mix(n, texture(rock_normal, tw.y > 0.5 ? world_pos.xz / 4.0 : (tw.x > tw.z ? world_pos.zy : world_pos.xy) / 4.0).rgb, m_rock);
	NORMAL_MAP = n;
	NORMAL_MAP_DEPTH = 1.0 - far * 0.7;
	ROUGHNESS = mix(0.94, 0.7, wetness);
	SPECULAR = 0.25;
	canopy = canopy_shade(world_pos) * mix(0.75, 1.0, far);
	AO = 1.0 - canopy * 0.55;
}

void light() {
	DIFFUSE_LIGHT += canopy_diffuse(NORMAL, LIGHT, ATTENUATION, LIGHT_COLOR, LIGHT_IS_DIRECTIONAL, canopy);
}
