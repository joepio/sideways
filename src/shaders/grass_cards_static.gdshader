shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;
#include "res://src/shaders/canopy.gdshaderinc"
// Static photographed grass tufts: retain their stage transforms, wind,
// lighting and distance fade. UV2 selects the unchanged clump atlas.
#include "res://src/shaders/lod_fade.gdshaderinc"

uniform sampler2D grass_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D grass_alpha : filter_linear_mipmap_anisotropic, repeat_disable;

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
	ALPHA = texture(grass_alpha, UV2).r;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	// Undo Godot's backface flip; GroundCover supplies its intended UP normal.
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
	// Match the photo carpet's colour response, with the existing static
	// per-instance shade. The photo already contains green and dry tips.
	vec3 col = texture(grass_albedo, UV2).rgb;
	ALBEDO = col * mix(0.8, 1.0, UV.y) * (1.0 - wetness * 0.25) * shade * 1.25;
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
