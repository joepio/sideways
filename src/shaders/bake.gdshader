shader_type spatial;
render_mode unshaded, cull_disabled;
// Used only when baking impostors: writes albedo (mode 0) or the view-space
// normal (mode 1) of a tree surface, with the needle cut-out.

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap;
uniform int mode = 0;
uniform bool cutout = false;
uniform vec3 tint = vec3(1.0);

void fragment() {
	vec4 c = texture(albedo_tex, UV);
	if (cutout && c.a < 0.42) discard;
	vec3 n = FRONT_FACING ? NORMAL : -NORMAL;
	if (mode == 1) {
		ALBEDO = n * 0.5 + 0.5;
	} else {
		ALBEDO = c.rgb * tint;
	}
}
