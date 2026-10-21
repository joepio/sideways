// Forest shade from Canopy (canopy.gd): call canopy_shade(world_pos) in
// fragment(), keep it in a varying, and use canopy_light() as light().
global uniform sampler2D canopy_map : filter_linear_mipmap;
global uniform vec4 canopy_rect; // origin x, z, 1 / width, 1 / depth in metres; zero when there is no map

float canopy_shade(vec3 world) {
	if (canopy_rect.z == 0.0) {
		return 0.0;
	}
	vec2 uv = (world.xz - canopy_rect.xy) * canopy_rect.zw;
	return clamp(texture(canopy_map, uv).r, 0.0, 0.92);
}

// Lambert sun and lamps, the sun dimmed by the canopy (but never darker
// than the real shadow says twice over: the darker of the two wins).
vec3 canopy_diffuse(vec3 n, vec3 l, float attenuation, vec3 color, bool directional, float shade) {
	float vis = directional ? min(attenuation, 1.0 - shade) : attenuation;
	return clamp(dot(n, l), 0.0, 1.0) * vis * color / PI;
}

// A plain normalised Blinn-Phong glint for wet gravel and puddles.
vec3 canopy_specular(vec3 n, vec3 l, vec3 v, float roughness, float attenuation, vec3 color, bool directional, float shade) {
	float vis = directional ? min(attenuation, 1.0 - shade) : attenuation;
	float shine = 2.0 / max(roughness * roughness * roughness * roughness, 0.0005) - 2.0;
	vec3 h = normalize(l + v);
	float s = pow(max(dot(n, h), 0.0), shine) * (shine + 8.0) / (8.0 * PI);
	return s * 0.06 * clamp(dot(n, l), 0.0, 1.0) * vis * color;
}

// 0 dry .. 1 soaked, set per stage by the weather (look.gd).
global uniform float wetness;
