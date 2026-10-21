shader_type spatial;
#include "res://src/shaders/canopy.gdshaderinc"
// Gravel road. UV.x runs -1..1 across the driven width, beyond that is the
// loose shoulder; UV.y is metres along the road.

uniform sampler2D gravel_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D gravel_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D gravel_rough : hint_roughness_r, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D gravel_height : hint_default_black, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D loose_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D loose_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;

// Tyre marks in road space (see track_map.gd): R packed, G thrown about.
uniform sampler2DArray track_map : filter_linear, repeat_disable;
const float TRACK_ALONG = 0.25;
const float TRACK_ROWS = 2048.0;
const float TRACK_TEXEL = 1.0 / 128.0;

varying vec3 world_pos;
varying vec3 shape; // the mesh's wheel tracks (r), middle ridge (g) and edge windrows (b)
varying float canopy;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}


vec2 track_at(vec2 uv, float du, float drow) {
	float row = uv.y / TRACK_ALONG + drow;
	float layer = floor(row / TRACK_ROWS);
	vec3 t = vec3((uv.x + 1.25) / 2.5 + du, (row - layer * TRACK_ROWS + 0.5) / TRACK_ROWS, layer);
	return texture(track_map, t).rg;
}

vec2 track(vec2 uv, float du) {
	return track_at(uv, du, 0.0);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	shape = COLOR.rgb;
}

void fragment() {
	vec2 wuv = world_pos.xz;
	// Parallax: stones stand up from the surface as the view grazes it.
	vec3 eye = normalize(CAMERA_POSITION_WORLD - world_pos);
	float near_fade = 1.0 - smoothstep(15.0, 40.0, length(CAMERA_POSITION_WORLD - world_pos));
	float hgt = texture(gravel_height, wuv / 2.6).r;
	wuv -= eye.xz / max(eye.y, 0.25) * (hgt - 0.5) * 0.045 * near_fade;
	vec2 tm = track(UV, 0.0);
	// Ruts: the packing is a groove pressed into the road. Its slopes across
	// and along tilt the normal, and the gravel it pushed aside lies in a
	// low bank beside it.
	float slope = track(UV, TRACK_TEXEL * 1.5).r - track(UV, -TRACK_TEXEL * 1.5).r;
	float slope_along = track_at(UV, 0.0, 1.5).r - track_at(UV, 0.0, -1.5).r;
	float bank = clamp(max(track(UV, TRACK_TEXEL * 4.0).r, track(UV, -TRACK_TEXEL * 4.0).r) - tm.r, 0.0, 1.0);
	float a = abs(UV.x);
	// Two worn wheel tracks where every car drives, from the mesh's shape.
	float rut = shape.r;
	float ridge = max(shape.g, shape.b);
	float edge = smoothstep(0.62, 0.95, a + (vnoise(wuv / 2.0) - 0.5) * 0.25);
	float shoulder = smoothstep(1.0, 1.2, a);
	vec3 g = texture(gravel_albedo, wuv / 2.6).rgb;
	vec3 g2 = texture(gravel_albedo, wuv / 11.0).rgb;
	g = mix(g, g2, 0.3);
	// Further off the single stones only sparkle and pop as dark specks:
	// fade them into the gravel's average colour.
	float far_d = smoothstep(10.0, 45.0, length(CAMERA_POSITION_WORLD - world_pos));
	g = mix(g, textureLod(gravel_albedo, wuv / 2.6, 9.0).rgb, far_d * 0.7);
	vec3 l = texture(loose_albedo, wuv / 2.2).rgb;
	// Finnish gravel is grey-brown and damp under the trees, not bleached.
	vec3 col = g * vec3(0.66, 0.62, 0.56);
	col = mix(col, col * 0.72, rut * 0.75);
	col = mix(col, mix(g * vec3(0.7, 0.66, 0.6), l * 0.8, 0.5), edge);
	col = mix(col, l * 0.7, shoulder);
	// Loose gravel heaped between the tracks and at the edges: lighter.
	col = mix(col, mix(g, l, 0.3) * vec3(0.78, 0.74, 0.68), ridge * 0.6);
	col *= 0.9 + 0.2 * vnoise(wuv / 7.0);
	// Little-used forest roads green over between the tracks: moss and
	// thin grass on the middle ridge in patches, never in the tracks.
	float green = smoothstep(0.45, 0.7, vnoise(wuv / 6.0 + 13.0)) * smoothstep(0.3, 0.8, shape.g) * smoothstep(0.35, 0.65, vnoise(wuv * 2.3));
	col = mix(col, vec3(0.2, 0.25, 0.11) * (0.8 + 0.4 * g.g), green * 0.75);
	// Darker damp gravel in big patches, lighter dry crowns.
	col *= 0.85 + 0.3 * smoothstep(0.3, 0.7, vnoise(wuv / 23.0 + 4.0));
	// Driven-in line: the stones are pushed away and the fine damp dirt
	// under them pressed flat, smeared along by the tread. Not a darker copy
	// of the gravel: a different, finer, browner surface that grows in with
	// every pass, and the loose stones heaped in banks beside it.
	float packed = smoothstep(0.0, 0.9, tm.r);
	float thrown = clamp(smoothstep(0.05, 0.8, tm.g) + bank * 0.6, 0.0, 1.0) * (0.55 + 0.45 * vnoise(wuv * 3.0));
	float smear = vnoise(vec2(UV.x * 70.0, UV.y * 0.6)) * 0.6 + vnoise(vec2(UV.x * 140.0, UV.y * 1.3)) * 0.4;
	vec3 fines = textureLod(gravel_albedo, wuv / 2.6, 6.0).rgb * vec3(0.66, 0.6, 0.52);
	vec3 mud = mix(fines, l * vec3(0.5, 0.44, 0.36), 0.35) * (0.82 + 0.3 * smear);
	mud *= mix(1.0, 0.7, wetness);
	col = mix(col, mud, packed * 0.7);
	col = mix(col, mix(g, l, 0.45) * vec3(0.8, 0.76, 0.7) * (0.9 + 0.25 * vnoise(wuv * 5.0)), thrown * 0.45);
	// Wet: darker gravel, and puddles in the worn tracks and dips that the
	// tyres keep packing.
	float puddle = smoothstep(0.55, 0.75, vnoise(wuv / 3.5) * 0.6 + rut * 0.35 + packed * 0.2 + vnoise(wuv / 0.9) * 0.15) * smoothstep(0.3, 0.9, wetness) * (1.0 - shoulder);
	col *= mix(1.0, 0.62, wetness);
	col = mix(col, col * 0.5, puddle);
	ALBEDO = col;
	vec3 nm = mix(mix(texture(gravel_normal, wuv / 2.6).rgb, vec3(0.5, 0.5, 1.0), rut * 0.5), texture(loose_normal, wuv / 2.2).rgb, max(max(edge * 0.5, shoulder), ridge * 0.5));
	nm = mix(nm, vec3(0.5 + (smear - 0.5) * 0.15, 0.5, 1.0), packed * 0.75);
	nm = mix(nm, texture(loose_normal, wuv / 1.4).rgb, thrown * 0.6);
	nm.x = clamp(nm.x + slope * 0.12, 0.0, 1.0);
	nm.y = clamp(nm.y - slope_along * 0.08, 0.0, 1.0);
	// Rain on the water's skin.
	vec2 ripple = vec2(vnoise(wuv * 4.0 + TIME * 0.7), vnoise(wuv * 4.0 - TIME * 0.6 + 9.0)) - 0.5;
	nm = mix(nm, vec3(0.5 + ripple * 0.06, 1.0), puddle);
	NORMAL_MAP = nm;
	NORMAL_MAP_DEPTH = mix(1.0, 0.4, far_d);
	float rough = mix(mix(texture(gravel_rough, wuv / 2.6).r, 0.75, rut * 0.6), mix(0.62, 0.4, wetness), packed * 0.7);
	rough = mix(rough, rough * 0.6, wetness);
	ROUGHNESS = mix(rough, 0.04, puddle);
	SPECULAR = mix(0.35 + wetness * 0.2, 0.5, puddle);
	canopy = canopy_shade(world_pos) * mix(0.75, 1.0, smoothstep(30.0, 140.0, length(world_pos - CAMERA_POSITION_WORLD)));
	AO = 1.0 - canopy * 0.45;
}

void light() {
	DIFFUSE_LIGHT += canopy_diffuse(NORMAL, LIGHT, ATTENUATION, LIGHT_COLOR, LIGHT_IS_DIRECTIONAL, canopy);
	SPECULAR_LIGHT += canopy_specular(NORMAL, LIGHT, VIEW, ROUGHNESS, ATTENUATION, LIGHT_COLOR, LIGHT_IS_DIRECTIONAL, canopy);
}
