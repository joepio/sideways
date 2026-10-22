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

// Keep half the coarse canopy overlap correction, but retain local caster
// contrast even when a soft real shadow is weaker than the canopy shade.
vec3 canopy_diffuse(vec3 n, vec3 l, float attenuation, vec3 color, bool directional, float shade) {
	float vis = directional ? mix(min(attenuation, 1.0 - shade), attenuation * (1.0 - shade), 0.5) : attenuation;
	return clamp(dot(n, l), 0.0, 1.0) * vis * color / PI;
}

// A plain normalised Blinn-Phong glint for wet gravel and puddles.
vec3 canopy_specular(vec3 n, vec3 l, vec3 v, float roughness, float attenuation, vec3 color, bool directional, float shade) {
	float vis = directional ? mix(min(attenuation, 1.0 - shade), attenuation * (1.0 - shade), 0.5) : attenuation;
	float r = clamp(roughness, 0.0, 1.0);
	float shine = max(2.0 / max(r * r * r * r, 0.0005) - 2.0, 0.0001);
	vec3 halfway = l + v;
	vec3 h = halfway / max(length(halfway), 0.0001);
	// pow(0, 0) is undefined for fully rough gravel. NaNs poison TAA
	// history and bloom, making black specks or bright blobs over the cars.
	float s = pow(max(dot(n, h), 0.0001), shine) * (shine + 8.0) / (8.0 * PI);
	return s * 0.06 * clamp(dot(n, l), 0.0, 1.0) * vis * color;
}

// 0 dry .. 1 soaked, set per stage by the weather (look.gd).
global uniform float wetness;
