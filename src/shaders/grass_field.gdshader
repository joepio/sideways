shader_type spatial;
render_mode cull_disabled;
#include "res://src/shaders/canopy.gdshaderinc"
#include "res://src/shaders/relief.gdshaderinc"
#include "res://src/shaders/vegetation_density.gdshaderinc"
#include "res://src/shaders/grass_coverage.gdshaderinc"
// Wind clock set by main.gd: with TIME in the vertex shader Godot drew the
// material a second time every frame for motion vectors (FSR 2, TAA).
global uniform float wind_time;
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
uniform float grow = 1.0; // fixed tuft size for this carpet, never a distance animation
uniform float jitter_strength = 1.6; // +/-0.8 cell; CPU padding includes this bound
uniform vec3 green : source_color = vec3(0.36, 0.46, 0.2);
uniform vec3 dry : source_color = vec3(0.62, 0.58, 0.36);
varying float canopy;
varying float tone;
varying vec3 world;
varying float coverage;

void vertex() {
	// The same world cell always gets the same root, jitter, angle and size.
	// Pool slots still recycle at cell snaps: their cross-frame motion-vector
	// identity is a separate limitation, not fixed by this geometry fade.
	// Centre the pool on the nearest cell: camera remainder is <=0.5 cell.
	vec2 camera_cell = floor(CAMERA_POSITION_WORLD.xz / cell + 0.5);
	vec2 slot = floor(MODEL_MATRIX[3].xz / cell + 0.5);
	vec2 id = camera_cell + slot;
	vec2 jitter = (vec2(vegetation_hash(id), vegetation_hash(id + 17.0)) - 0.5) * jitter_strength;
	vec2 xz = (id + jitter) * cell;
	float d = length(xz - CAMERA_POSITION_WORLD.xz);
	vec3 g = vegetation_ground(xz);
	float scale = grow * mix(0.7, 1.3, vegetation_hash(id + 9.0));
	coverage = 0.0;
	if (d < radius && d > inner - 4.0) {
		float shade = canopy_shade(vec3(xz.x, 0.0, xz.y));
		float density = kind == 0 ? vegetation_grass_density(xz, g, shade) : vegetation_shrub_density(xz, g, shade);
		coverage = density * grass_ring_coverage(xz, d, inner, radius);
	}
	coverage_seed = vegetation_hash(id + 53.0);
	float ang = vegetation_hash(id + 3.0) * 6.2832;
	mat2 rot = mat2(vec2(cos(ang), sin(ang)), vec2(-sin(ang), cos(ang)));
	vec3 v = VERTEX * scale;
	v.xz = rot * v.xz;
	vec3 n = NORMAL;
	n.xz = rot * n.xz;
	// Wind, more towards the tips; shrubs hardly move.
	float tip = UV.y * UV.y * (kind == 0 ? 1.0 : 0.25);
	float t = wind_time * 1.7 + xz.x * 0.23 + xz.y * 0.19;
	v.x += sin(t) * 0.05 * tip * scale;
	v.z += cos(t * 0.8) * 0.035 * tip * scale;
	// Keep even fully faded vertices grounded: no collapsed previous geometry.
	float lift = relief(vec3(xz.x, g.x, xz.y), min(g.y, 14.0), g.z);
	world = vec3(xz.x, g.x + lift - 0.02, xz.y) + v;
	VERTEX = world - MODEL_MATRIX[3].xyz;
	NORMAL = kind == 0 ? vec3(0.0, 1.0, 0.0) : normalize(n);
	tone = vegetation_noise(xz / 5.0) * 0.6 + vegetation_hash(id + 2.0) * 0.4;
}

void fragment() {
	// Spatial opacity dissolve stays in the opaque depth path. Photo alpha
	// still cuts out individual blades; geometry/height never follows opacity.
	if (grass_coverage_sample(UV, coverage_seed) >= coverage) discard;
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
