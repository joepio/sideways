// Shared world-space grass distribution, independent of camera distance.
// Ground map channels: terrain height, metres from road edge, coarse normal Y.
global uniform sampler2D ground_map : filter_linear;
global uniform vec4 ground_rect;

float vegetation_hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vegetation_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(vegetation_hash(i), vegetation_hash(i + vec2(1, 0)), f.x), mix(vegetation_hash(i + vec2(0, 1)), vegetation_hash(i + vec2(1, 1)), f.x), f.y);
}

vec3 vegetation_ground(vec2 xz) {
	vec2 size = vec2(textureSize(ground_map, 0));
	vec2 uv = ((xz - ground_rect.xy) / ground_rect.z + 0.5) / size;
	if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) {
		return vec3(-1000.0, 999.0, 0.0);
	}
	return texture(ground_map, uv).rgb;
}

float vegetation_grass_density(vec2 xz, vec3 ground, float shade) {
	float level = smoothstep(0.7, 0.82, ground.z);
	float verge = smoothstep(0.5, 1.4, ground.y) * (1.0 - smoothstep(10.0, 22.0, ground.y));
	float wood = smoothstep(0.3, 0.6, vegetation_noise(xz / 7.0)) * 0.85 * smoothstep(1.0, 3.0, ground.y);
	return max(verge, wood) * (1.0 - shade * 0.45) * level;
}

float vegetation_shrub_density(vec2 xz, vec3 ground, float shade) {
	float patch = smoothstep(0.28, 0.5, vegetation_noise(xz / 9.0 + 31.0) * 0.7 + vegetation_noise(xz / 2.5) * 0.3);
	return patch * smoothstep(2.5, 6.0, ground.y) * (0.7 + shade * 0.5) * smoothstep(0.7, 0.82, ground.z);
}
