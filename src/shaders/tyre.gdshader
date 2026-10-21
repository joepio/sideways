shader_type spatial;
// A tyre that gives under load: flat where it meets the ground, bulging a
// little at the sides there, and its wall leaning with the side force. Car
// sets the per-wheel values every tick (all in this mesh's own space).

uniform vec4 albedo : source_color = vec4(0.05, 0.05, 0.05, 1.0);
uniform sampler2D albedo_tex : source_color, hint_default_white, filter_linear_mipmap_anisotropic;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic;
uniform bool use_normal = false;
uniform float roughness = 0.88;
uniform float metallic = 0.0;
// glTF metallic-roughness map: roughness in G, metal in B (rims share the
// tyre's texture on some models).
uniform sampler2D mr_tex : hint_default_white, filter_linear_mipmap_anisotropic;
instance uniform vec3 contact_dir = vec3(0.0, -1.0, 0.0); // hub to contact patch, unit
instance uniform vec3 axle_dir = vec3(1.0, 0.0, 0.0);
instance uniform vec3 hub = vec3(0.0);
instance uniform float radius = 0.33;
instance uniform float squash = 0.0; // metres the tread flattens
instance uniform float lean = 0.0; // metres the bottom of the wall moves along the axle

void vertex() {
	vec3 rel = VERTEX - hub;
	float toward = dot(rel, contact_dir);
	float flat_at = radius - squash;
	if (toward > flat_at) {
		VERTEX -= contact_dir * (toward - flat_at);
	}
	// Near the patch the wall bulges out and leans with the side force.
	float near = smoothstep(flat_at - squash * 3.0 - 0.02, radius, toward);
	float side = dot(rel, axle_dir);
	VERTEX += axle_dir * (sign(side) * squash * 0.6 * near + lean * near);
}

void fragment() {
	ALBEDO = albedo.rgb * texture(albedo_tex, UV).rgb;
	if (use_normal) {
		NORMAL_MAP = texture(normal_tex, UV).rgb;
	}
	vec4 mr = texture(mr_tex, UV);
	ROUGHNESS = roughness * mr.g;
	METALLIC = metallic * mr.b;
}
