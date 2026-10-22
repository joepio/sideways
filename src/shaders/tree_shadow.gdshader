shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;
// Used only by Forest's shadow-only MultiMeshes. Visible tree and grass
// shaders are untouched. One shared material per variant/surface, with
// each block's static world AABB centre and existing cull end in the
// MultiMesh's four-float custom data, avoiding global instance-uniform slots.
uniform bool foliage = false;
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;
uniform float alpha_cut = 0.42;
uniform float sway = 0.04;
uniform float shadow_fade_width = 12.0;
varying flat float shadow_coverage;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

void vertex() {
	// Exactly the current foliage shader's world-origin seed and wind.
	// Opaque wood retains its original unmodified positions.
	if (foliage) {
		vec3 origin = MODEL_MATRIX[3].xyz;
		float h = hash(origin.xz);
		float t = TIME * (0.9 + 0.3 * h);
		float bend = sway * max(VERTEX.y - 3.0, 0.0) / 12.0;
		VERTEX.x += sin(t + origin.x * 0.05 + VERTEX.y * 0.3) * bend;
		VERTEX.z += cos(t * 0.8 + origin.z * 0.05) * bend * 0.7;
	}
	vec4 tree_shadow_block = INSTANCE_CUSTOM;
	shadow_coverage = 1.0;
	if (IN_SHADOW_PASS && tree_shadow_block.w > 0.0) {
		// Godot 4.5.2 passes the actual view camera separately from the light
		// camera. MAIN_CAM is vertex-only; pass one constant coverage per block.
		float distance_to_view = distance(tree_shadow_block.xyz, MAIN_CAM_INV_VIEW_MATRIX[3].xyz);
		float width = min(shadow_fade_width, tree_shadow_block.w);
		shadow_coverage = 1.0 - smoothstep(tree_shadow_block.w - width, tree_shadow_block.w, distance_to_view);
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
