shader_type spatial;
#include "res://src/shaders/canopy.gdshaderinc"
#include "res://src/shaders/relief.gdshaderinc"
#include "res://src/shaders/vegetation_density.gdshaderinc"
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
varying float grass_cover;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}
float fbm(vec2 p) { return vnoise(p) * 0.55 + vnoise(p * 2.1) * 0.3 + vnoise(p * 4.3) * 0.15; }

const mat2 TURN = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8));

vec3 layer(sampler2D tex, vec2 uv, float scale, float far, float mixer) {
	vec3 a = texture(tex, uv / scale).rgb;
	vec3 b = texture(tex, TURN * uv / (scale * 4.3)).rgb;
	return mix(a, b, clamp(mixer + far * 0.4, 0.0, 1.0));
}

// Rock projected three ways from the side so it doesn't stretch down a face,
// each at two scales (the second turned) blended by noise, so no repeat of
// the 4 m texture lines up with the next.
vec3 rock_tex(sampler2D tex, vec3 p, vec3 tw, float mixer) {
	vec2 px = p.zy, py = p.xz, pz = p.xy;
	vec3 a = texture(tex, px / 3.7).rgb * tw.x + texture(tex, py / 3.7).rgb * tw.y + texture(tex, pz / 3.7).rgb * tw.z;
	vec3 b = texture(tex, TURN * px / 11.3 + 0.37).rgb * tw.x + texture(tex, TURN * py / 11.3 + 0.37).rgb * tw.y + texture(tex, TURN * pz / 11.3 + 0.37).rgb * tw.z;
	return mix(a, b, mixer);
}

void vertex() {
	// Terrain chunks sit at the origin: model space is world space.
	road_d = COLOR.r;
	up = NORMAL.y;
	float h = relief(VERTEX, road_d * 14.0, NORMAL.y);
	if (h > 0.0) {
		NORMAL = relief_normal(VERTEX, NORMAL, road_d * 14.0, h);
		VERTEX.y += h;
	}
	world_pos = VERTEX;
	wn = NORMAL;
	// Reuse the exact carpet distribution on the ground, including the full
	// road distance (COLOR.r saturates at 14 m). Per vertex, no extra fragment
	// texture read. Patches remain when the grass geometry fades with range.
	vec3 cover_ground = vegetation_ground(world_pos.xz);
	grass_cover = vegetation_grass_density(world_pos.xz, cover_ground, canopy_shade(world_pos));
}

void fragment() {
	vec2 uv = world_pos.xz;
	float far = smoothstep(30.0, 140.0, length(world_pos - CAMERA_POSITION_WORLD));
	float lmix = smoothstep(0.2, 0.8, fbm(uv / 8.0 + 21.0)) * 0.6;
	vec3 moss = layer(moss_albedo, uv, 3.2, far, lmix) * vec3(0.78, 0.86, 0.7);
	vec3 needles = layer(needles_albedo, uv, 2.8, far, lmix) * vec3(0.72, 0.66, 0.6);
	vec3 verge = layer(verge_albedo, uv, 2.6, far, lmix) * vec3(0.68, 0.94, 0.70);
	// Tint matches the alpha-tested linear mean of the existing grass photo
	// approximately, while retaining this ground texture's local detail.
	vec3 ground = layer(ground_albedo, uv, 3.0, far, lmix) * vec3(0.85, 0.8, 0.75);
	float m_needles = smoothstep(0.48, 0.62, fbm(uv / 11.0 + 7.0));
	float m_verge = clamp(grass_cover, 0.0, 1.0);
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
	vec3 n = mix(texture(moss_normal, uv / 3.2).rgb, texture(needles_normal, uv / 2.8).rgb, m_needles);
	n = mix(n, texture(verge_normal, uv / 2.6).rgb, m_verge);
	n = mix(n, texture(ground_normal, uv / 3.0).rgb, m_bare);
	// Flat ground has exactly zero rock weight. Avoid twelve triplanar
	// texture reads and the cliff's noise there, retaining the same blend
	// and full detail wherever the rock contributes.
	if (m_rock > 0.0) {
		vec3 tw = pow(abs(wn), vec3(4.0));
		tw /= tw.x + tw.y + tw.z;
		vec2 rp = world_pos.xz + world_pos.yy * 0.7;
		float rmix = smoothstep(0.25, 0.75, fbm(rp / 6.0 + 3.0));
		vec3 rock = rock_tex(rock_albedo, world_pos, tw, rmix) * vec3(0.62, 0.63, 0.62);
		// Bedding: faint bands that wander across the face, and lichen and
		// stain patches at the scale of the whole cut.
		float strata = 0.88 + 0.12 * sin(world_pos.y * 2.1 + fbm(rp / 5.0) * 5.0);
		float stain = fbm(rp / 17.0 + 11.0);
		rock *= strata * (0.75 + 0.45 * stain);
		rock = mix(rock, rock * vec3(0.85, 0.95, 0.7), smoothstep(0.55, 0.75, fbm(rp / 3.0 + 5.0)) * 0.6);
		col = mix(col, rock, m_rock);
		n = mix(n, rock_tex(rock_normal, world_pos, tw, rmix), m_rock);
	}
	col *= mix(1.0, 0.7, wetness);
	ALBEDO = col;
	NORMAL_MAP = n;
	NORMAL_MAP_DEPTH = 1.0 - far * 0.7;
	ROUGHNESS = mix(0.94, 0.7, wetness);
	SPECULAR = 0.25;
	// Match the road's existing near strength without a moving shade envelope.
	canopy = canopy_shade(world_pos) * 0.75;
	AO = 1.0 - canopy * 0.55;
}

void light() {
	DIFFUSE_LIGHT += canopy_diffuse(NORMAL, LIGHT, ATTENUATION, LIGHT_COLOR, LIGHT_IS_DIRECTIONAL, canopy);
}
