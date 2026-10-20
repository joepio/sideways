shader_type spatial;
// Forest floor: pine needles, moss patches, and bare stony ground beside the
// road (COLOR.r is the distance from the road edge, 0..14 m mapped to 0..1).

uniform sampler2D leaves_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D leaves_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D ground_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D ground_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D moss_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D moss_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;

varying vec3 world_pos;
varying float road_d;
varying float up;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}
float fbm(vec2 p) { return vnoise(p) * 0.55 + vnoise(p * 2.1) * 0.3 + vnoise(p * 4.3) * 0.15; }

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	road_d = COLOR.r;
	up = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz).y;
}

void fragment() {
	vec2 uv = world_pos.xz;
	float far_blend = smoothstep(30.0, 120.0, length(world_pos - CAMERA_POSITION_WORLD));
	vec3 lv = mix(texture(leaves_albedo, uv / 3.5).rgb, texture(leaves_albedo, uv / 17.0).rgb, 0.35 + far_blend * 0.4);
	vec3 gr = mix(texture(ground_albedo, uv / 3.0).rgb, texture(ground_albedo, uv / 13.0).rgb, 0.3 + far_blend * 0.4);
	vec3 ms = texture(moss_albedo, uv / 2.5).rgb * vec3(0.42, 0.56, 0.28);
	// Needle litter under spruce reads brown-green, not autumn orange.
	lv *= vec3(0.6, 0.62, 0.42);
	gr *= vec3(0.8, 0.76, 0.7);
	vec3 ln = texture(leaves_normal, uv / 3.5).rgb;
	vec3 gn = texture(ground_normal, uv / 3.0).rgb;
	vec3 mn = texture(moss_normal, uv / 2.5).rgb;
	float moss = smoothstep(0.42, 0.6, fbm(uv / 9.0)) * smoothstep(0.05, 0.4, road_d);
	float bare = 1.0 - smoothstep(0.08, 0.32, road_d + (fbm(uv / 3.0) - 0.5) * 0.25);
	// Steep banks show soil.
	float steep = smoothstep(0.80, 0.62, up);
	bare = max(bare, steep * 0.7);
	vec3 col = mix(lv, ms, moss);
	col = mix(col, gr, bare);
	col *= 0.85 + 0.3 * fbm(uv / 23.0);
	ALBEDO = col;
	NORMAL_MAP = mix(mix(ln, mn, moss), gn, bare);
	NORMAL_MAP_DEPTH = 1.0 - far_blend * 0.7;
	ROUGHNESS = 0.92;
	SPECULAR = 0.3;
}
