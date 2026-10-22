shader_type spatial;
#include "res://src/shaders/canopy.gdshaderinc"
// Road sections. UV.x runs -1..1 across the driven width, beyond that is the
// loose shoulder; UV.y is metres along the road.

// Stage's exact row descriptor: float surface ID and physical half width.
// This is data, not colour; never mip/filter across a grip boundary.
uniform sampler2D road_surface_map : filter_nearest, repeat_disable;
uniform float road_surface_step = 2.0;

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
varying vec2 road_right;
varying float canopy;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}

// Material weights only. The nearest descriptor row remains the grip/FX
// authority; feather a narrow surface dressing across its exact boundary.
vec3 section_weights(float surface_id) {
	int type = int(round(surface_id));
	return vec3(type == 3 || type == 6 ? 1.0 : 0.0, type == 6 ? 1.0 : 0.0, type == 5 ? 1.0 : 0.0);
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
	road_right = UV2;
	// The road is built without UV tangents, and its stone textures use
	// world X/Z rather than the ribbon's across/along UVs. Supply that basis
	// explicitly so normal-map relief follows the ground through bends.
	TANGENT = normalize(vec3(1.0, -NORMAL.x / max(NORMAL.y, 0.1), 0.0));
	BINORMAL = normalize(cross(TANGENT, NORMAL));
}

void fragment() {
	vec2 wuv = world_pos.xz;
	float rows = float(textureSize(road_surface_map, 0).x);
	float row = clamp(floor(UV.y / road_surface_step), 0.0, rows - 1.0);
	vec2 section = texture(road_surface_map, vec2((row + 0.5) / rows, 0.5)).rg;
	vec3 materials = section_weights(section.r);
	float phase = mod(UV.y, road_surface_step);
	float boundary_distance = min(phase, road_surface_step - phase);
	float dressing_width = mix(0.28, 0.65, vnoise(vec2(UV.x * 3.0, UV.y * 0.5)));
	if (boundary_distance < dressing_width) {
		int neighbour = int(clamp(row + (phase < road_surface_step * 0.5 ? -1.0 : 1.0), 0.0, rows - 1.0));
		vec3 adjacent = section_weights(texelFetch(road_surface_map, ivec2(neighbour, 0), 0).r);
		materials = mix(materials, adjacent, 0.5 * (1.0 - smoothstep(0.0, dressing_width, boundary_distance)));
	}
	// The 50% line still coincides with the physical firm/loose edge. Narrow
	// gravel/soil dressing breaks up the ruler-straight coloured stripe.
	float edge_width = mix(0.18, 0.4, vnoise(wuv * 1.7));
	float firm = 1.0 - smoothstep(section.g - 0.9 - edge_width, section.g - 0.9 + edge_width, abs(UV.x) * section.g);
	float earth = materials.x * firm;
	float muddy = materials.y * firm;
	float asphalt = materials.z * firm;
	float road_wet = mix(wetness, max(wetness, 0.55), muddy);
	// Parallax: stones stand up from the surface as the view grazes it.
	vec3 eye = normalize(CAMERA_POSITION_WORLD - world_pos);
	float near_fade = 1.0 - smoothstep(15.0, 40.0, length(CAMERA_POSITION_WORLD - world_pos));
	float hgt = texture(gravel_height, wuv / 2.6).r;
	wuv -= eye.xz / max(eye.y, 0.25) * (hgt - 0.5) * 0.045 * near_fade * (1.0 - asphalt);
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
	// The same source aggregate becomes fine asphalt grain, with no extra fetch.
	float aggregate_scale = mix(2.6, 0.65, asphalt);
	vec3 g = texture(gravel_albedo, wuv / aggregate_scale).rgb;
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
	float smear = vnoise(vec2(UV.x * 70.0, UV.y * 0.6)) * 0.6 + vnoise(vec2(UV.x * 140.0, UV.y * 1.3)) * 0.4;
	// The road has seen traffic before this race. Reuse the authored rut
	// mask and existing smear detail, while fresh tracks remain independent.
	// This changes appearance only; it does not prefill the gameplay map.
	float worn = clamp(rut * (0.65 + 0.35 * smear), 0.0, 1.0);
	float fresh = smoothstep(0.0, 0.55, tm.r);
	float packed = max(worn, fresh);
	float thrown = clamp(smoothstep(0.05, 0.8, tm.g) + bank * 0.6, 0.0, 1.0) * (0.55 + 0.45 * vnoise(wuv * 3.0));
	thrown *= 1.0 - asphalt;
	vec3 fines = textureLod(gravel_albedo, wuv / 2.6, 6.0).rgb * vec3(0.66, 0.6, 0.52);
	vec3 mud = mix(fines, l * vec3(0.5, 0.44, 0.36), 0.35) * (0.82 + 0.3 * smear);
	mud *= mix(1.0, 0.7, road_wet);
	col = mix(col, mud, packed * 0.85);
	col = mix(col, mix(g, l, 0.45) * vec3(0.8, 0.76, 0.7) * (0.9 + 0.25 * vnoise(wuv * 5.0)), thrown * 0.45);
	// Wet: darker gravel, and puddles in the worn tracks and dips that the
	// tyres keep packing.
	float puddle = smoothstep(0.55, 0.75, vnoise(wuv / 3.5) * 0.6 + rut * 0.35 + packed * 0.2 + vnoise(wuv / 0.9) * 0.15) * smoothstep(0.3, 0.9, road_wet) * (1.0 - shoulder);
	col *= mix(1.0, 0.62, road_wet);
	col = mix(col, col * 0.5, puddle);
	// Reuse already sampled fines/soil; earth sections are not tinted stones.
	vec3 earth_col = mix(g2 * vec3(0.55, 0.40, 0.26), l * vec3(0.65, 0.50, 0.35), 0.4);
	earth_col *= (0.9 + 0.2 * smear) * mix(1.0, 0.65, road_wet) * (1.0 - puddle * 0.35);
	earth_col *= 1.0 - fresh * 0.18;
	col = mix(col, earth_col, earth);
	// Fine asphalt aggregate: no gravel parallax, green ridge, or thrown banks.
	// Keep existing physical road geometry; these are worn forest-road links.
	vec3 asphalt_col = vec3(0.065, 0.068, 0.070) * (0.65 + 0.7 * dot(g, vec3(0.333333)));
	asphalt_col *= mix(1.0, 0.88, worn);
	asphalt_col *= mix(1.0, 0.7, wetness) * (1.0 - fresh * 0.2) * (1.0 - puddle * 0.25);
	col = mix(col, asphalt_col, asphalt);
	ALBEDO = col;
	vec3 nm = mix(mix(texture(gravel_normal, wuv / aggregate_scale).rgb, vec3(0.5, 0.5, 1.0), rut * 0.5), texture(loose_normal, wuv / 2.2).rgb, max(max(edge * 0.5, shoulder), ridge * 0.5));
	vec2 across = normalize(road_right);
	vec2 along = vec2(across.y, -across.x);
	nm = mix(nm, vec3(vec2(0.5) + across * (smear - 0.5) * 0.15, 1.0), packed * 0.75);
	nm = mix(nm, texture(loose_normal, wuv / 1.4).rgb, thrown * 0.6);
	nm.xy = clamp(nm.xy + across * slope * 0.12 + along * slope_along * 0.08, vec2(0.0), vec2(1.0));
	nm = mix(nm, mix(nm, vec3(0.5, 0.5, 1.0), mix(0.55, 0.75, muddy)), earth);
	nm = mix(nm, mix(vec3(0.5, 0.5, 1.0), nm, 0.16), asphalt);
	// Rain on the water's skin.
	vec2 ripple = vec2(vnoise(wuv * 4.0 + TIME * 0.7), vnoise(wuv * 4.0 - TIME * 0.6 + 9.0)) - 0.5;
	nm = mix(nm, vec3(0.5 + ripple * 0.06, 1.0), puddle);
	NORMAL_MAP = nm;
	NORMAL_MAP_DEPTH = mix(1.0, 0.4, far_d);
	float rough = mix(mix(texture(gravel_rough, wuv / 2.6).r, 0.75, rut * 0.6), mix(0.62, 0.4, road_wet), packed * 0.7);
	rough = mix(rough, rough * 0.6, road_wet);
	rough = mix(rough, mix(0.9, 0.56, road_wet), earth);
	rough = mix(rough, mix(0.88, 0.28, wetness), asphalt);
	ROUGHNESS = mix(rough, 0.04, puddle);
	SPECULAR = mix(0.35 + road_wet * 0.2, 0.5, puddle);
	// World-space tree cover must not brighten as the camera approaches.
	canopy = canopy_shade(world_pos) * 0.75;
	AO = 1.0 - canopy * 0.45;
}

void light() {
	DIFFUSE_LIGHT += canopy_diffuse(NORMAL, LIGHT, ATTENUATION, LIGHT_COLOR, LIGHT_IS_DIRECTIONAL, canopy);
	SPECULAR_LIGHT += canopy_specular(NORMAL, LIGHT, VIEW, ROUGHNESS, ATTENUATION, LIGHT_COLOR, LIGHT_IS_DIRECTIONAL, canopy);
}
