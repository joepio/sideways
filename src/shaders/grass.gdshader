shader_type spatial;
render_mode cull_disabled;
#include "res://src/shaders/canopy.gdshaderinc"
// Grass tufts: tapered blades coloured by vertex (dark at the root, dry tips),
// bending in the wind more towards the tip, dissolving out with distance.
#include "res://src/shaders/lod_fade.gdshaderinc"

uniform vec3 tint : source_color = vec3(0.62, 0.66, 0.55);

varying vec3 origin;
varying float shade;
varying float canopy;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

void vertex() {
	origin = MODEL_MATRIX[3].xyz;
	float h = hash(origin.xz);
	shade = 0.8 + 0.4 * h;
	float tip = UV.y * UV.y;
	float t = TIME * 1.6 + origin.x * 0.21 + origin.z * 0.17;
	VERTEX.x += sin(t) * 0.06 * tip;
	VERTEX.z += cos(t * 0.7) * 0.04 * tip;
	// Blades face up for lighting, as grass seen from afar reads as a surface.
	NORMAL = normalize(mix(NORMAL, vec3(0.0, 1.0, 0.0), 0.4));
}

void fragment() {
	lod_fade(origin, CAMERA_POSITION_WORLD, FRAGCOORD.xy, PROJECTION_MATRIX);
	ALBEDO = COLOR.rgb * tint * shade;
	ROUGHNESS = 0.9;
	SPECULAR = 0.2;
	canopy = canopy_shade(origin);
	AO = mix(0.5, 1.0, UV.y) * (1.0 - canopy * 0.5);
	AO_LIGHT_AFFECT = 0.4;
}

void light() {
	DIFFUSE_LIGHT += canopy_diffuse(NORMAL, LIGHT, ATTENUATION, LIGHT_COLOR, LIGHT_IS_DIRECTIONAL, canopy);
	// Light through the blades from behind.
	float vis = LIGHT_IS_DIRECTIONAL ? min(ATTENUATION, 1.0 - canopy) : ATTENUATION;
	DIFFUSE_LIGHT += vec3(0.12, 0.16, 0.05) * clamp(-dot(NORMAL, LIGHT), 0.0, 1.0) * vis * LIGHT_COLOR / PI;
}
