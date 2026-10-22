shader_type spatial;
render_mode cull_disabled;
// A far tree: a quad that turns round the trunk to face the camera and shows
// the baked view of the tree closest to the camera's direction. Albedo and
// normals come from the bake, so the sun lights it like the near trees.
#include "res://src/shaders/lod_fade.gdshaderinc"

uniform sampler2D albedo_atlas : source_color, filter_linear_mipmap;
// bake.gdshader writes encoded normals through ALBEDO into an sRGB PNG.
// Decode that transfer curve before explicitly unpacking all three signed axes.
uniform sampler2D normal_atlas : source_color, filter_linear_mipmap;
uniform int row = 0;
uniform int rows = 3;
uniform int views = 8;

varying vec2 cell_uv;
varying float view_f;
varying float shade;
varying vec3 origin;
// Capture the actual MultiMesh basis here: fragment MODEL_MATRIX omits it.
// Raw instance scaling follows current near rendering; mapped normals under
// nonuniform Y scaling remain approximate because the atlas has no separate TBN.
varying vec3 stored_normal_to_view_x;
varying vec3 stored_normal_to_view_y;
varying vec3 stored_normal_to_view_z;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

void vertex() {
	stored_normal_to_view_x = (VIEW_MATRIX * vec4(MODEL_MATRIX[0].xyz, 0.0)).xyz;
	stored_normal_to_view_y = (VIEW_MATRIX * vec4(MODEL_MATRIX[1].xyz, 0.0)).xyz;
	stored_normal_to_view_z = (VIEW_MATRIX * vec4(MODEL_MATRIX[2].xyz, 0.0)).xyz;
	vec3 cam = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
	vec2 dir = normalize(cam.xz + vec2(0.0001));
	vec2 right = vec2(dir.y, -dir.x);
	cell_uv = UV;
	VERTEX = vec3(right.x * VERTEX.x, VERTEX.y, right.y * VERTEX.x);
	NORMAL = vec3(dir.x, 0.0, dir.y);
	TANGENT = vec3(right.x, 0.0, right.y);
	BINORMAL = vec3(0.0, 1.0, 0.0);
	float a = atan(dir.x, dir.y);
	view_f = fract(a / TAU) * float(views);
	origin = MODEL_MATRIX[3].xyz;
	shade = 0.82 + 0.3 * hash(origin.xz);
}

void fragment() {
	lod_fade(origin, CAMERA_POSITION_WORLD, FRAGCOORD.xy, PROJECTION_MATRIX);
	// Pick the nearer of the two closest views per pixel, dithered, so a turn
	// of the camera cross-fades instead of popping.
	float v0 = floor(view_f);
	float t = view_f - v0;
	float noise = fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715)) * 52.9829189);
	float v = mod(t > noise ? v0 + 1.0 : v0, float(views));
	vec2 uv = vec2((v + cell_uv.x) / float(views), (float(row) + cell_uv.y) / float(rows));
	vec4 c = texture(albedo_atlas, uv);
	ALPHA = c.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ALBEDO = c.rgb * shade;
	// foliage-mapped-bake-view-v1: the chosen cell defines the stored basis,
	// not the continuously facing quad. Decode signed Z rather than NORMAL_MAP.
	vec3 baked_normal = texture(normal_atlas, uv).rgb * 2.0 - 1.0;
	if (dot(baked_normal, baked_normal) <= 0.000001) {
		baked_normal = vec3(0.0, 0.0, 1.0);
	}
	float baked_angle = TAU * v / float(views);
	float ca = cos(baked_angle);
	float sa = sin(baked_angle);
	vec3 local_normal = vec3(ca * baked_normal.x + sa * baked_normal.z,
		baked_normal.y, -sa * baked_normal.x + ca * baked_normal.z);
	NORMAL = normalize(stored_normal_to_view_x * local_normal.x
		+ stored_normal_to_view_y * local_normal.y
		+ stored_normal_to_view_z * local_normal.z);
	ROUGHNESS = 0.9;
	SPECULAR = 0.2;
	BACKLIGHT = vec3(0.175, 0.21, 0.1);
	AO = 0.85;
}
