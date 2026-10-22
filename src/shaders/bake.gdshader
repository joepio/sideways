shader_type spatial;
render_mode unshaded, cull_disabled;
// Used only when baking impostors: writes albedo (mode 0) or the view-space
// normal (mode 1) of a tree surface, with the needle cut-out.

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap;
// Same sampler semantics as foliage.gdshader; source normal textures can be RG-packed.
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic;
uniform bool use_foliage_normal = false;
uniform int mode = 0;
uniform bool cutout = false;
uniform vec3 tint = vec3(1.0);

void fragment() {
	vec4 c = texture(albedo_tex, UV);
	if (cutout && c.a < 0.42) discard;
	if (mode == 1) {
		// Preserve the old geometry-only wood bake; its bark mapping remains approximate.
		vec3 n = FRONT_FACING ? NORMAL : -NORMAL;
		if (use_foliage_normal) {
			vec2 xy = texture(normal_tex, UV).rg * 2.0 - 1.0;
			float z = sqrt(max(0.0, 1.0 - dot(xy, xy)));
			// Godot already flips NORMAL on cull_disabled backfaces, not T/B.
			// Keep the interpolated TBN unnormalized, exactly as NORMAL_MAP does.
			n = TANGENT * xy.x + BINORMAL * xy.y + NORMAL * z;
			if (dot(n, n) <= 0.000001) n = NORMAL;
			if (dot(n, n) <= 0.000001) n = vec3(0.0, 0.0, 1.0);
			n = normalize(n);
		}
		// Signed bake-view XYZ through the existing ALBEDO -> sRGB PNG path.
		ALBEDO = n * 0.5 + 0.5;
	} else {
		ALBEDO = c.rgb * tint;
	}
}
