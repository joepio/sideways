class_name Look
## The light, sky and fonts: a late summer afternoon in a Finnish forest.
## Sky is a Poly Haven HDRI; the sun is placed where the HDRI has its sun.

const SKY := preload("res://assets/sky/sky_2k.hdr")
const SUN_ELEVATION := 30.0
const SUN_AZIMUTH := 125.0 ## degrees, measured from -Z towards +X: across the stage's general heading, so trees shade the road
const HDRI_SUN_AZIMUTH := 196.0 ## where the sun is in the HDRI; the sky is turned to match

static var wetness := 0.0 ## the stage's, also the `wetness` shader global
static var _font: Font
static var _title: Font


static func environment() -> Environment:
	var env := Environment.new()
	var sky := Sky.new()
	var mat := PanoramaSkyMaterial.new()
	mat.panorama = SKY
	mat.energy_multiplier = 1.0
	sky.sky_material = mat
	sky.radiance_size = Sky.RADIANCE_SIZE_256
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.8
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 0.95
	env.tonemap_white = 6.0
	env.ssao_enabled = true
	env.ssao_radius = 1.4
	env.ssao_intensity = 1.6
	env.glow_enabled = true
	env.glow_intensity = 0.25
	env.glow_bloom = 0.04
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = Color(0.62, 0.68, 0.72)
	env.fog_depth_begin = 120.0
	env.fog_depth_end = 700.0
	env.fog_density = 1.0
	env.fog_aerial_perspective = 0.6
	env.fog_sky_affect = 0.0
	env.adjustment_enabled = true
	env.adjustment_saturation = 0.92
	env.adjustment_contrast = 1.04
	return env


static func sun() -> DirectionalLight3D:
	var l := DirectionalLight3D.new()
	l.name = "Sun"
	var dir := sun_direction()
	l.basis = Basis.looking_at(-dir, Vector3.UP if absf(dir.y) < 0.99 else Vector3.FORWARD)
	l.light_color = Color(1.0, 0.93, 0.82)
	l.light_energy = 1.6
	l.shadow_enabled = true
	l.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	l.directional_shadow_max_distance = 160.0
	l.directional_shadow_split_1 = 0.06
	l.directional_shadow_split_2 = 0.18
	l.directional_shadow_split_3 = 0.45
	l.shadow_blur = 1.2
	# Blend the cascades so their edges don't show as lines across the road.
	l.directional_shadow_blend_splits = true
	l.shadow_normal_bias = 1.6
	l.shadow_bias = 0.04
	l.light_angular_distance = 0.6
	return l


const WEATHERS := ["clear", "overcast", "mist", "wet"]


## Sets the sky, sun, fog and road wetness for a stage. The forest wants
## contrast: the sky lights far less than the sun, so shade under the trees
## reads as shade (it used to be lit almost as brightly as the road).
static func weather(env: Environment, sun_light: DirectionalLight3D, kind: String) -> void:
	var clear := kind == "clear"
	if clear:
		var mat := PanoramaSkyMaterial.new()
		mat.panorama = SKY
		env.sky.sky_material = mat
		env.sky_rotation.y = deg_to_rad(HDRI_SUN_AZIMUTH - SUN_AZIMUTH)
	else:
		var grey := ProceduralSkyMaterial.new()
		var top := Color(0.42, 0.46, 0.5) if kind != "mist" else Color(0.6, 0.62, 0.63)
		grey.sky_top_color = top
		grey.sky_horizon_color = top.lightened(0.25)
		grey.ground_horizon_color = top.lightened(0.15)
		grey.ground_bottom_color = top.darkened(0.5)
		grey.sky_energy_multiplier = 0.9 if kind == "mist" else 0.75
		grey.sun_angle_max = 0.0
		env.sky.sky_material = grey
	match kind:
		"clear":
			sun_light.light_energy = 2.6
			sun_light.shadow_opacity = 1.0
			_ambient(env, 0.36, 0.35)
			env.tonemap_exposure = 1.0
			env.fog_mode = Environment.FOG_MODE_DEPTH
			env.fog_light_color = Color(0.62, 0.68, 0.72)
			env.fog_depth_begin = 90.0
			env.fog_depth_end = 650.0
			env.fog_height = 0.0
			env.fog_height_density = 0.0
			RenderingServer.global_shader_parameter_set("wetness", 0.0)
			wetness = 0.0
		"overcast":
			sun_light.light_energy = 0.9
			sun_light.shadow_opacity = 0.6
			_ambient(env, 0.65, 0.4)
			env.tonemap_exposure = 1.15
			env.fog_mode = Environment.FOG_MODE_DEPTH
			env.fog_light_color = Color(0.55, 0.58, 0.6)
			env.fog_depth_begin = 50.0
			env.fog_depth_end = 420.0
			env.fog_height = 0.0
			env.fog_height_density = 0.0
			RenderingServer.global_shader_parameter_set("wetness", 0.25)
			wetness = 0.25
		"mist":
			# Morning mist: lying in the low ground, thick down the road.
			sun_light.light_energy = 1.1
			sun_light.shadow_opacity = 0.7
			_ambient(env, 0.65, 0.45)
			env.tonemap_exposure = 1.05
			env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
			env.fog_light_color = Color(0.68, 0.7, 0.7)
			env.fog_density = 0.011
			env.fog_sun_scatter = 0.25
			env.fog_height = 6.0
			env.fog_height_density = 0.06
			RenderingServer.global_shader_parameter_set("wetness", 0.45)
			wetness = 0.45
		"wet":
			# Just after rain: grey, dark gravel, puddles in the tracks.
			sun_light.light_energy = 0.8
			sun_light.shadow_opacity = 0.5
			_ambient(env, 0.6, 0.35)
			env.tonemap_exposure = 1.2
			env.fog_mode = Environment.FOG_MODE_DEPTH
			env.fog_light_color = Color(0.5, 0.54, 0.56)
			env.fog_depth_begin = 30.0
			env.fog_depth_end = 320.0
			env.fog_height = 0.0
			env.fog_height_density = 0.0
			RenderingServer.global_shader_parameter_set("wetness", 1.0)
			wetness = 1.0
	CarLights.headlight_energy = {"clear": 0.3, "overcast": 0.8, "mist": 1.0, "wet": 0.9}.get(kind, 1.0)
	if kind != "mist":
		env.fog_density = 1.0
		env.fog_sun_scatter = 0.0


## How much of the sky's own light reaches the ground (the rest is a dim
## blue-grey fill). The ambient energy alone does nothing while the sky
## contributes fully, which is why shade used to be nearly as bright as sun.
static func _ambient(env: Environment, sky_share: float, fill: float) -> void:
	env.ambient_light_sky_contribution = sky_share
	env.ambient_light_color = Color(0.5, 0.56, 0.62)
	env.ambient_light_energy = fill


## Unit vector towards the sun.
static func sun_direction() -> Vector3:
	var el := deg_to_rad(SUN_ELEVATION)
	var az := deg_to_rad(SUN_AZIMUTH)
	return Vector3(sin(az) * cos(el), sin(el), -cos(az) * cos(el))


static func font() -> Font:
	if _font == null:
		_font = load("res://assets/fonts/BarlowCondensed-SemiBold.ttf")
	return _font


static func title_font() -> Font:
	if _title == null:
		_title = load("res://assets/fonts/BarlowCondensed-ExtraBoldItalic.ttf")
	return _title
