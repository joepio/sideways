shader_type spatial;
// Gravel road. UV.x runs -1..1 across the driven width, beyond that is the
// loose shoulder; UV.y is metres along the road.

uniform sampler2D gravel_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D gravel_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D gravel_rough : hint_roughness_r, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D loose_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D loose_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;

// Tyre marks in road space (see track_map.gd): R packed, G thrown about.
uniform sampler2DArray track_map : filter_linear, repeat_disable;
const float TRACK_ALONG = 0.25;
const float TRACK_ROWS = 2048.0;
const float TRACK_TEXEL = 1.0 / 128.0;

varying vec3 world_pos;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

vec2 track(vec2 uv, float du) {
	float row = uv.y / TRACK_ALONG;
	float layer = floor(row / TRACK_ROWS);
	vec3 t = vec3((uv.x + 1.25) / 2.5 + du, (row - layer * TRACK_ROWS + 0.5) / TRACK_ROWS, layer);
	return texture(track_map, t).rg;
}

void fragment() {
	vec2 wuv = world_pos.xz;
	vec2 tm = track(UV, 0.0);
	// Groove sides: the slope of the packing across the road tilts the normal.
	float slope = track(UV, TRACK_TEXEL).r - track(UV, -TRACK_TEXEL).r;
	float a = abs(UV.x);
	float wobble = (vnoise(vec2(UV.y / 9.0, 3.0)) - 0.5) * 0.18;
	// Two worn wheel tracks where every car drives.
	float rut = exp(-pow((a - 0.24 + wobble) / 0.09, 2.0));
	float edge = smoothstep(0.62, 0.95, a + (vnoise(wuv / 2.0) - 0.5) * 0.25);
	float shoulder = smoothstep(1.0, 1.2, a);
	vec3 g = texture(gravel_albedo, wuv / 2.6).rgb;
	vec3 g2 = texture(gravel_albedo, wuv / 11.0).rgb;
	g = mix(g, g2, 0.3);
	vec3 l = texture(loose_albedo, wuv / 2.2).rgb;
	// Finnish gravel is grey-brown and damp under the trees, not bleached.
	vec3 col = g * vec3(0.66, 0.62, 0.56);
	col = mix(col, col * 0.72, rut * 0.75);
	col = mix(col, mix(g * vec3(0.7, 0.66, 0.6), l * 0.8, 0.5), edge);
	col = mix(col, l * 0.7, shoulder);
	col *= 0.9 + 0.2 * vnoise(wuv / 7.0);
	// Fresh tyre marks: packed gravel is darker and smoother, thrown gravel
	// lighter and lumpier.
	float packed = smoothstep(0.0, 0.9, tm.r);
	float thrown = smoothstep(0.05, 0.8, tm.g) * (0.6 + 0.4 * vnoise(wuv * 3.0));
	col = mix(col, col * 0.68, packed * 0.8);
	col = mix(col, mix(col, l * 0.85, 0.5) * 1.12, thrown * 0.7);
	ALBEDO = col;
	vec3 nm = mix(mix(texture(gravel_normal, wuv / 2.6).rgb, vec3(0.5, 0.5, 1.0), rut * 0.5), texture(loose_normal, wuv / 2.2).rgb, max(edge * 0.5, shoulder));
	nm = mix(nm, vec3(0.5, 0.5, 1.0), packed * 0.6);
	nm = mix(nm, texture(loose_normal, wuv / 1.4).rgb, thrown * 0.6);
	nm.x = clamp(nm.x + slope * 1.6, 0.0, 1.0);
	NORMAL_MAP = nm;
	ROUGHNESS = mix(mix(texture(gravel_rough, wuv / 2.6).r, 0.75, rut * 0.6), 0.68, packed * 0.5);
	SPECULAR = 0.35;
}
