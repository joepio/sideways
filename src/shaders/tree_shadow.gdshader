shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;
// Shared by per-view TreeSets shadow meshes. The mesh's world origin gives
// per-tree XZ distance; no per-block custom data or global instance uniforms.
// The same global clock as foliage keeps crown wind aligned in both passes.
global uniform float wind_time;
uniform bool foliage = false;
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;
uniform float alpha_cut = 0.42;
uniform float sway = 0.04;
uniform float shadow_fade_width = 12.0;
uniform float shadow_fade_end = 33.0;
varying flat float shadow_coverage;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

void vertex() {
	// Exactly the current foliage shader's world-origin seed and wind.
	// Opaque wood retains its original unmodified positions.
	vec3 origin = MODEL_MATRIX[3].xyz;
	if (foliage) {
		float h = hash(origin.xz);
		float t = wind_time * (0.9 + 0.3 * h);
		float bend = sway * max(VERTEX.y - 3.0, 0.0) / 12.0;
		VERTEX.x += sin(t + origin.x * 0.05 + VERTEX.y * 0.3) * bend;
		VERTEX.z += cos(t * 0.8 + origin.z * 0.05) * bend * 0.7;
	}
	shadow_coverage = 1.0;
	if (IN_SHADOW_PASS && shadow_fade_end > 0.0) {
		// MAIN_CAM is the real view camera, not the shadow light camera.
		// Match TreeSets' ground-plane selection; height never shortens range.
		float distance_to_view = distance(origin.xz, MAIN_CAM_INV_VIEW_MATRIX[3].xz);
		float width = min(shadow_fade_width, shadow_fade_end);
		shadow_coverage = 1.0 - smoothstep(shadow_fade_end - width, shadow_fade_end, distance_to_view);
	}
}

void fragment() {
	if (IN_SHADOW_PASS && shadow_coverage < 1.0) {
		// Same spatial pattern family as the existing tree dissolve, evaluated
		// in shadow-map pixels. PCF filters the sparse shadow coverage.
		float noise = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
		if (noise >= shadow_coverage) discard;
	}
	ALPHA = foliage ? texture(albedo_tex, UV).a : 1.0;
	ALPHA_SCISSOR_THRESHOLD = foliage ? alpha_cut : 0.0;
}
