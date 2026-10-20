// Dithered cross-fade between a tree's levels of detail. Both levels use
// the same screen pattern, one keeps the pixels the other drops, so the swap
// is a short dissolve with no holes and no pop. Distance is to the tree's
// origin, so a whole tree fades together. A value below 0 turns that side off.
uniform float fade_in_at = -1.0;
uniform float fade_out_at = -1.0;
uniform float fade_in_width = 12.0;
uniform float fade_out_width = 12.0;

void lod_fade(vec3 origin, vec3 camera, vec2 frag, mat4 projection) {
	// Shadow maps are drawn with an orthographic sun camera: no dissolve there,
	// so trees keep their shadow while they swap.
	if (projection[3][3] > 0.5) return;
	float d = distance(origin.xz, camera.xz);
	float n = fract(52.9829189 * fract(dot(frag, vec2(0.06711056, 0.00583715))));
	if (fade_out_at >= 0.0) {
		float t = smoothstep(fade_out_at - fade_out_width * 0.5, fade_out_at + fade_out_width * 0.5, d);
		if (n >= 1.0 - t) discard;
	}
	if (fade_in_at >= 0.0) {
		float t = smoothstep(fade_in_at - fade_in_width * 0.5, fade_in_at + fade_in_width * 0.5, d);
		if (n < 1.0 - t) discard;
	}
}
