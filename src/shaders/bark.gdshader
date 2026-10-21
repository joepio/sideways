shader_type spatial;
render_mode cull_disabled;
// Tree bark and branches, with the level-of-detail dissolve.
#include "res://src/shaders/lod_fade.gdshaderinc"

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool triplanar = false;

varying vec3 origin;
varying vec3 local_pos;
varying vec3 local_nrm;

void vertex() {
	origin = MODEL_MATRIX[3].xyz;
	local_pos = VERTEX;
	local_nrm = NORMAL;
	if (lod_fully_hidden(origin, CAMERA_POSITION_WORLD, PROJECTION_MATRIX)) {
		VERTEX = vec3(0.0);
	}
}

void fragment() {
	lod_fade(origin, CAMERA_POSITION_WORLD, FRAGCOORD.xy, PROJECTION_MATRIX);
	vec2 uv = UV;
	if (triplanar) {
		// Round trunk without UVs: wrap the texture around by angle.
		uv = vec2(atan(local_pos.x, local_pos.z) / 6.2831853 * 1.5, local_pos.y * 0.5);
	}
	ALBEDO = texture(albedo_tex, uv).rgb;
	NORMAL_MAP = texture(normal_tex, uv).rgb;
	ROUGHNESS = 0.95;
}
