shader_type particles;
render_mode disable_velocity, disable_force;

// Fixed per material: dust 0, debris 1, spray 2. Each has two GPU batches;
// INDEX % 4 distributes their unchanged total capacity over all four tyres.
uniform int effect = 0;
// Birth-only wheel inputs. An in-flight particle never reads these again.
uniform mat4 wheel_frames[4];
uniform vec4 wheel_launches[4]; // xyz launch velocity, w Surfaces enum
uniform vec3 wheel_velocities[4];
uniform vec3 wheel_rates[4]; // dust, debris, water
global uniform float wetness;

float random_unit(inout uint seed) {
	seed = seed * 1664525u + 1013904223u;
	return float(seed & 16777215u) / 16777216.0;
}

mat3 turn(vec3 axis, float angle) {
	float c = cos(angle);
	float s = sin(angle);
	float t = 1.0 - c;
	return mat3(
	vec3(c + axis.x * axis.x * t, axis.y * axis.x * t + axis.z * s, axis.z * axis.x * t - axis.y * s),
	vec3(axis.x * axis.y * t - axis.z * s, c + axis.y * axis.y * t, axis.z * axis.y * t + axis.x * s),
	vec3(axis.x * axis.z * t + axis.y * s, axis.y * axis.z * t - axis.x * s, c + axis.z * axis.z * t));
}

void start() {
	uint seed = (NUMBER + 1u) * 747796405u + RANDOM_SEED;
	int wheel = int(INDEX % 4u);
	if (random_unit(seed) >= wheel_rates[wheel][effect] * AMOUNT_RATIO) {
		ACTIVE = false;
	} else {
		int surface_type = int(wheel_launches[wheel].w);
		mat4 frame = wheel_frames[wheel];
		vec3 launch = wheel_launches[wheel].xyz;
		vec3 scatter = vec3(random_unit(seed) - 0.5, random_unit(seed) * 0.35, random_unit(seed) - 0.5);
		TRANSFORM = mat4(1.0);
		TRANSFORM[3].xyz = (frame * vec4(random_unit(seed) * 0.2 - 0.1, 0.0, random_unit(seed) * 0.16 - 0.08, 1.0)).xyz;
		// Billboard convention: angle in x and normalized age in y. z is unused.
		CUSTOM = vec4(random_unit(seed) * TAU, 0.0, 0.0, float(surface_type));
		// Saved random scale, angular velocity, tumble azimuth and damping.
		USERDATA1 = vec4(1.0, mix(-0.35, 0.35, random_unit(seed)), random_unit(seed) * TAU, mix(1.2, 2.0, random_unit(seed)));
		if (effect != 1) {
			bool spray = effect == 2;
			USERDATA1.x = spray ? mix(0.5, 1.2, random_unit(seed)) : mix(0.8, 1.4, random_unit(seed));
			USERDATA1.w = spray ? mix(0.5, 1.0, random_unit(seed)) : USERDATA1.w;
			COLOR = spray ? vec4(0.9, 0.92, 0.9, 0.7) : vec4(0.42, 0.38, 0.32, 0.0);
			float speed = spray ? mix(2.5, 6.5, random_unit(seed)) : mix(1.0, 3.5, random_unit(seed));
			VELOCITY = mat3(frame) * normalize(launch + scatter) * speed;
			VELOCITY += wheel_velocities[wheel] * (spray ? 0.4 : 0.15);
			float scale = USERDATA1.x * (spray ? 1.0 : 0.7);
			TRANSFORM[0].xyz *= scale;
			TRANSFORM[1].xyz *= scale;
			TRANSFORM[2].xyz *= scale;
		} else {
			float size = mix(0.65, 1.35, random_unit(seed));
			// Colours are linear; the regular opaque material uses particle COLOR.
			vec3 tint = mix(vec3(0.075, 0.064, 0.05), vec3(0.15, 0.13, 0.105), random_unit(seed));
			vec3 dimensions = vec3(0.025, 0.020, 0.023);
			if (surface_type == 1) {
				// Loose grit is mostly smaller grains with an occasional larger clod.
				dimensions = vec3(0.022, 0.018, 0.02) * mix(0.45, 1.0, random_unit(seed));
				tint = mix(vec3(0.075, 0.052, 0.028), vec3(0.15, 0.11, 0.064), random_unit(seed));
			} else if (surface_type == 2) {
				// A flattened, tapered solid: no square card and no alpha overdraw.
				dimensions = vec3(0.009, 0.065, 0.002);
				tint = mix(vec3(0.025, 0.045, 0.009), vec3(0.095, 0.13, 0.028), random_unit(seed));
			} else if (surface_type == 3) {
				dimensions = vec3(0.03, 0.022, 0.026);
				tint = mix(vec3(0.055, 0.035, 0.018), vec3(0.105, 0.075, 0.04), random_unit(seed));
			} else if (surface_type == 6) {
				dimensions = vec3(0.034, 0.024, 0.03);
				tint = mix(vec3(0.035, 0.022, 0.012), vec3(0.075, 0.048, 0.026), random_unit(seed));
			}
			COLOR = vec4(tint * mix(1.0, 0.72, clamp(wetness, 0.0, 1.0)), 1.0);
			USERDATA1.y = mix(-7.0, 7.0, random_unit(seed));
			vec3 axis = normalize(vec3(cos(USERDATA1.z), 0.6, sin(USERDATA1.z)));
			mat3 rotation = turn(axis, random_unit(seed) * TAU);
			TRANSFORM[0].xyz = rotation[0] * dimensions.x * size;
			TRANSFORM[1].xyz = rotation[1] * dimensions.y * size;
			TRANSFORM[2].xyz = rotation[2] * dimensions.z * size;
			VELOCITY = mat3(frame) * (launch * mix(0.75, 1.25, random_unit(seed)) + scatter);
			VELOCITY += wheel_velocities[wheel] * 0.3;
		}
	}
}

void process() {
	CUSTOM.y += DELTA / LIFETIME;
	if (CUSTOM.y >= 1.0) {
		ACTIVE = false;
	} else {
		if (effect != 1) {
			bool spray = effect == 2;
			VELOCITY += vec3(0.0, spray ? -9.8 : 0.15, 0.0) * DELTA;
			float speed = length(VELOCITY);
			VELOCITY *= max(0.0, speed - USERDATA1.w * DELTA) / max(speed, 0.0001);
			TRANSFORM[3].xyz += VELOCITY * DELTA;
			CUSTOM.x += USERDATA1.y * DELTA;
			float age = CUSTOM.y;
			float growth = age < 0.3 ? mix(0.7, 2.0, age / 0.3) : mix(2.0, 3.8, (age - 0.3) / 0.7);
			float scale = USERDATA1.x * (spray ? 1.0 : growth);
			TRANSFORM[0].xyz = vec3(scale, 0.0, 0.0);
			TRANSFORM[1].xyz = vec3(0.0, scale, 0.0);
			TRANSFORM[2].xyz = vec3(0.0, 0.0, scale);
			float dust_alpha = age < 0.06 ? mix(0.0, 0.42, age / 0.06) : (age < 0.5 ? mix(0.42, 0.22, (age - 0.06) / 0.44) : mix(0.22, 0.0, (age - 0.5) / 0.5));
			COLOR.a = spray ? 0.7 * (1.0 - age) : dust_alpha;
		} else {
			// Only this particle's saved birth type controls drag. Live solid
			// colour and dimensions are never replaced by a later surface's values.
			float drag = CUSTOM.w == 2.0 ? 2.5 : 0.25;
			VELOCITY += vec3(0.0, -9.8, 0.0) * DELTA;
			VELOCITY *= exp(-drag * DELTA);
			TRANSFORM[3].xyz += VELOCITY * DELTA;
			vec3 axis = normalize(vec3(cos(USERDATA1.z), 0.6, sin(USERDATA1.z)));
			mat3 rotation = turn(axis, USERDATA1.y * DELTA);
			TRANSFORM[0].xyz = rotation * TRANSFORM[0].xyz;
			TRANSFORM[1].xyz = rotation * TRANSFORM[1].xyz;
			TRANSFORM[2].xyz = rotation * TRANSFORM[2].xyz;
		}
	}
}
