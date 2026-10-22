shader_type spatial;
render_mode cull_disabled;
#include "res://src/shaders/canopy.gdshaderinc"
#include "res://src/shaders/relief.gdshaderinc"
// The ground cover carpets (grass_field.gd). Each instance is a fixed offset
// from the camera's cell, so the ring follows the camera in whole cells.
// kind 0 is grass (verge and clearings), kind 1 bilberry and lingonberry
// shrubs (the wood floor, in the shade), turning red in autumn.
// A carpet covers `inner`..`radius` metres from the camera; carpets that
// meet dither into each other.

uniform int kind = 0;
uniform float cell = 0.5;
uniform float inner = 0.0;
uniform float radius = 40.0;
uniform float grow = 1.0; // tuft size, for the coarser far carpet
uniform vec3 green : source_color = vec3(0.36, 0.46, 0.2);
uniform vec3 dry : source_color = vec3(0.62, 0.58, 0.36);
global uniform sampler2D ground_map : filter_linear;
global uniform vec4 ground_rect; // origin x, z, metres per texel

varying float canopy;
varying float tone;
varying vec3 world;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}

vec3 ground(vec2 xz) {
	vec2 size = vec2(textureSize(ground_map, 0));
	vec2 uv = ((xz - ground_rect.xy) / ground_rect.z + 0.5) / size;
	if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) {
		return vec3(-1000.0, 999.0, 0.0);
	}
	return texture(ground_map, uv).rgb;
}

void vertex() {
	vec2 offset = MODEL_MATRIX[3].xz;
	vec2 cam = floor(CAMERA_POSITION_WORLD.xz / cell) * cell;
	vec2 base = cam + offset;
	vec2 id = floor(base / cell + 0.5);
	vec2 jitter = vec2(hash(id), hash(id + 17.0)) - 0.5;
	vec2 xz = base + jitter * cell * 0.9;
	float d = length(xz - CAMERA_POSITION_WORLD.xz);
	float scale = 0.0;
	vec3 g = vec3(0.0);
	float shade = 0.0;
	if (d < radius && d > inner - 4.0) {
		g = ground(xz);
		shade = canopy_shade(vec3(xz.x, 0.0, xz.y));
		float level = smoothstep(0.7, 0.82, g.z);
		float density;
		if (kind == 0) {
			// None on the road and shoulder, thick on the verge, patchy in
			// the wood and thinner under the trees.
			float verge = smoothstep(0.5, 1.4, g.y) * (1.0 - smoothstep(10.0, 22.0, g.y));
			float wood = smoothstep(0.3, 0.6, vnoise(xz / 7.0)) * 0.85 * smoothstep(1.0, 3.0, g.y);
			density = max(verge, wood) * (1.0 - shade * 0.45) * level;
		} else {
			// Berry shrubs carpet the wood floor in big patches, most in the
			// shade, and creep onto the outer verge.
			float patch = smoothstep(0.28, 0.5, vnoise(xz / 9.0 + 31.0) * 0.7 + vnoise(xz / 2.5) * 0.3);
			density = patch * smoothstep(2.5, 6.0, g.y) * (0.7 + shade * 0.5) * level;
		}
		// Thin out with distance; the survivors grow a little to fill in.
		float keep = density * mix(1.0, 0.45, smoothstep(inner + 8.0, radius, d));
		keep *= smoothstep(inner - 4.0, inner, d) * (1.0 - smoothstep(radius * 0.7, radius, d));
		// Tufts grow in and shrink away over a stretch of distance instead of
		// switching on and off, which showed as grass popping in.
		float alive = clamp((keep - hash(id + 5.0)) / 0.25, 0.0, 1.0);
		scale = alive * grow * mix(0.7, 1.3, hash(id + 9.0)) * mix(1.0, 1.4, smoothstep(inner + 8.0, radius, d));
	}
	float ang = hash(id + 3.0) * 6.2832;
	mat2 rot = mat2(vec2(cos(ang), sin(ang)), vec2(-sin(ang), cos(ang)));
	vec3 v = VERTEX * scale;
	v.xz = rot * v.xz;
	vec3 n = NORMAL;
	n.xz = rot * n.xz;
	// Wind, more towards the tips; shrubs hardly move.
	float tip = UV.y * UV.y * (kind == 0 ? 1.0 : 0.25);
	float t = TIME * 1.7 + xz.x * 0.23 + xz.y * 0.19;
	v.x += sin(t) * 0.05 * tip * scale;
	v.z += cos(t * 0.8) * 0.035 * tip * scale;
	float lift = scale > 0.0 ? relief(vec3(xz.x, g.x, xz.y), min(g.y, 14.0), g.z) : 0.0;
	world = vec3(xz.x, g.x + lift - 0.02, xz.y) + v;
	VERTEX = world - MODEL_MATRIX[3].xyz;
	NORMAL = kind == 0 ? vec3(0.0, 1.0, 0.0) : normalize(n);
	tone = vnoise(xz / 5.0) * 0.6 + hash(id + 2.0) * 0.4;
}

void fragment() {
	// Godot flips cull_disabled backface normals before fragment().
	// Keep the authored grass and shrub lighting normals on both sides.
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
	canopy = canopy_shade(world);
	// Grass dries towards the tips; shrubs are green or turned, patch by patch.
	vec3 col = kind == 0 ? mix(green, dry, tone * 0.7 + UV.y * 0.3) : mix(green, dry, smoothstep(0.5, 0.75, tone));
	ALBEDO = col * mix(0.45, 1.0, UV.y) * (1.0 - wetness * 0.25);
	ROUGHNESS = kind == 0 ? 0.85 : 0.8;
	SPECULAR = kind == 0 ? 0.2 : 0.15;
	AO = mix(0.45, 1.0, UV.y) * (1.0 - canopy * 0.5);
	AO_LIGHT_AFFECT = 0.4;
}

void light() {
	DIFFUSE_LIGHT += canopy_diffuse(NORMAL, LIGHT, ATTENUATION, LIGHT_COLOR, LIGHT_IS_DIRECTIONAL, canopy);
	float vis = LIGHT_IS_DIRECTIONAL ? min(ATTENUATION, 1.0 - canopy) : ATTENUATION;
	DIFFUSE_LIGHT += vec3(0.12, 0.16, 0.05) * clamp(-dot(NORMAL, LIGHT), 0.0, 1.0) * vis * LIGHT_COLOR / PI;
}
