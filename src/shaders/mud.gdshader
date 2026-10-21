shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_back;
// Mud and dust on a car, drawn over its own materials (material_overlay).
// `dirt` (0 clean .. 1 caked) is set per car as it drives: the mud climbs
// from the sills up the doors and is heaviest behind the wheels and at the
// back; dust settles everywhere a little. Wet stages make it dark and shiny.
#include "res://src/shaders/canopy.gdshaderinc"

uniform sampler2D mud_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform float low = -0.2; // body bottom in car space
uniform float high = 1.1;
uniform float rear = 2.0;
instance uniform float dirt = 0.0;

varying vec3 local;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}
float fbm(vec2 p) { return vnoise(p) * 0.5 + vnoise(p * 2.7) * 0.3 + vnoise(p * 6.1) * 0.2; }

void vertex() {
	// In the mesh's own space: the body's is the car's, a wheel's turns with
	// the wheel, so mud on the tyres goes round with them.
	local = VERTEX;
}

void fragment() {
	float h = clamp((local.y - low) / (high - low), 0.0, 1.0);
	float back = smoothstep(rear - 1.2, rear, local.z);
	vec2 p = local.xz * 2.2 + local.yy * 3.1;
	float splat = fbm(p * 1.6 + local.zx * 0.7);
	// The tide line rises with the dirt, fading up into spatter.
	float line = dirt * (0.55 + back * 0.3) + (splat - 0.5) * 0.25;
	float caked = smoothstep(h - 0.02, h + 0.12, line);
	float spots = smoothstep(0.62, 0.8, vnoise(local.xz * 19.0 + local.yy * 23.0)) * (1.0 - smoothstep(line, line + 0.3, h));
	float dust = dirt * 0.38 * (0.6 + 0.4 * splat) * (1.0 - h * 0.6);
	float a = max(max(caked * (0.7 + 0.3 * splat), spots * dirt * 0.9), dust);
	// Mostly flat dried-mud colour, a little of the photo for grain.
	vec3 grain = texture(mud_tex, p * 0.5).rgb;
	vec3 m = mix(vec3(0.30, 0.25, 0.19), grain * vec3(0.62, 0.55, 0.46), 0.35);
	m = mix(m * 1.15, m, caked); // thin dust is lighter
	m = mix(m, m * 0.55, wetness);
	ALBEDO = m;
	ROUGHNESS = mix(0.92, 0.35, wetness * caked);
	SPECULAR = 0.3;
	ALPHA = clamp(a, 0.0, 0.95);
}
