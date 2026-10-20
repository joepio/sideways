class_name Look
## The light, sky and fonts: a late summer afternoon in a Finnish forest.
## Sky is a Poly Haven HDRI; the sun is placed where the HDRI has its sun.

const SKY := preload("res://assets/sky/sky_2k.hdr")
const SUN_ELEVATION := 38.0
const SUN_AZIMUTH := 196.0 ## degrees, measured from -Z towards +X

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
	l.light_angular_distance = 0.6
	return l


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
