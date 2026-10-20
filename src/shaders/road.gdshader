shader_type spatial;
// Gravel road. UV.x runs -1..1 across the driven width, beyond that is the
// loose shoulder; UV.y is metres along the road.

uniform sampler2D gravel_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D gravel_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D gravel_rough : hint_roughness_r, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D loose_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D loose_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;

varying vec3 world_pos;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 wuv = world_pos.xz;
	float a = abs(UV.x);
	float wobble = (vnoise(vec2(UV.y / 9.0, 3.0)) - 0.5) * 0.18;
	// Two worn wheel tracks where every car drives.
	float rut = exp(-pow((a - 0.24 + wobble) / 0.09, 2.0));
	float edge = smoothstep(0.62, 0.95, a + (vnoise(wuv / 2.0) - 0.5) * 0.25);
	float shoulder = smoothstep(1.0, 1.2, a);
	vec3 g = texture(gravel_albedo, wuv / 2.6).rgb;
	vec3 g2 = texture(gravel_albedo, wuv / 11.0).rgb;
	g = mix(g, g2, 0.3);
	vec3 l = texture(loose_albedo, wuv / 2.2).rgb;
	vec3 col = g * vec3(1.0, 0.97, 0.92);
	col = mix(col, col * 0.72, rut * 0.75);
	col = mix(col, mix(g, l, 0.45) * 1.05, edge);
	col = mix(col, l * 0.9, shoulder);
	col *= 0.9 + 0.2 * vnoise(wuv / 7.0);
	ALBEDO = col;
	NORMAL_MAP = mix(mix(texture(gravel_normal, wuv / 2.6).rgb, vec3(0.5, 0.5, 1.0), rut * 0.5), texture(loose_normal, wuv / 2.2).rgb, max(edge * 0.5, shoulder));
	ROUGHNESS = mix(texture(gravel_rough, wuv / 2.6).r, 0.75, rut * 0.6);
	SPECULAR = 0.35;
}
