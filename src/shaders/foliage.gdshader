shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;
// Needle cards: alpha cut-out, light shining through from behind, a gentle
// sway that grows with height, and a little colour variation per tree.

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic;
uniform float alpha_cut = 0.42;
uniform vec3 tint : source_color = vec3(0.62, 0.66, 0.55);
uniform float sway = 0.04;

varying float shade;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	float h = hash(origin.xz);
	shade = 0.82 + 0.3 * h;
	float t = TIME * (0.9 + 0.3 * h);
	float bend = sway * max(VERTEX.y - 3.0, 0.0) / 12.0;
	VERTEX.x += sin(t + origin.x * 0.05 + VERTEX.y * 0.3) * bend;
	VERTEX.z += cos(t * 0.8 + origin.z * 0.05) * bend * 0.7;
}

void fragment() {
	vec4 c = texture(albedo_tex, UV);
	ALPHA = c.a;
	ALPHA_SCISSOR_THRESHOLD = alpha_cut;
	ALBEDO = c.rgb * tint * shade;
	NORMAL_MAP = texture(normal_tex, UV).rgb;
	ROUGHNESS = 0.85;
	SPECULAR = 0.25;
	BACKLIGHT = vec3(0.35, 0.42, 0.2);
	AO = 0.85;
}
