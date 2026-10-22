extends SceneTree
## Actual mesh/UV/texture/material and built MultiMesh metadata contract.
## Explicit --gpu adds real-renderer instance-transform readback assertions.
## The dummy renderer ignores instance transforms; headless cannot prove placement.
## Neither mode renders pixels or validates shader lighting/temporal quality.

const HEIGHT := 0.50
const HALF_WIDTH := 0.36 * (257.0 / 135.0) * 0.5
const ATLAS_MIN := Vector2(580.5 / 1024.0, 889.5 / 1024.0)
const ATLAS_MAX := Vector2(836.5 / 1024.0, 1023.5 / 1024.0)
const ALBEDO := "res://assets/grass/grass_medium_01_diff_2k.jpg"
const ALPHA := "res://assets/grass/grass_medium_01_alpha_2k.png"
const CARPET := "res://src/shaders/grass_cards.gdshader"
const STATIC := "res://src/shaders/grass_cards_static.gdshader"
const SHRUB := "res://src/shaders/grass_field.gdshader"
const HIGH := [[0, 0.3, 0.0, 20.0, 1.0], [0, 0.7, 18.0, 60.0, 1.35], [0, 1.6, 52.0, 110.0, 2.0], [1, 0.55, 0.0, 30.0, 1.0]]
const MEDIUM := [[0, 0.42, 0.0, 16.0, 1.1], [0, 0.9, 14.0, 45.0, 1.5], [0, 1.8, 40.0, 85.0, 2.1], [1, 0.75, 0.0, 22.0, 1.15]]
const LOW := [[0, 0.6, 0.0, 32.0, 1.25], [0, 1.8, 28.0, 65.0, 2.0]]

var failures: Array[String] = []
var check_placement := false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	check_placement = "--gpu" in OS.get_cmdline_user_args()
	if check_placement and DisplayServer.get_name() == "headless":
		printerr("photo grass GPU: --gpu requires a real renderer, not --headless")
		quit(1)
		return
	if check_placement:
		_check_transform_readback()
	_check_factories()
	_check_static_placement()
	for views in range(1, 5):
		_check_carpet(views)
	# build() retains this ImageTexture through a renderer global. Release it
	# after the helper has returned, including its local Resource references.
	RenderingServer.global_shader_parameter_set("ground_map", RID())
	if not failures.is_empty():
		for failure in failures:
			printerr("photo grass: ", failure)
		quit(1)
		return
	print("photo grass: mesh/UV/root/mips/materials, static instance counts and auto1-4 grid properties passed")
	if check_placement:
		print("photo grass GPU: static transform multiset and auto1-4 grid placement readback passed")
	else:
		print("photo grass: placement readback not requested; use --gpu with a real renderer")
	quit()


func _check_transform_readback() -> void:
	# Fail rather than silently dropping placement assertions on an unsupported
	# backend, including a non-headless invocation forced to a dummy renderer.
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.instance_count = 1
	mm.mesh = BoxMesh.new()
	var wanted := Transform3D(Basis(Vector3.UP, 0.4).scaled(Vector3(0.8, 1.1, 0.8)), Vector3(1, 2, 3))
	mm.set_instance_transform(0, wanted)
	_check(mm.get_instance_transform(0).is_equal_approx(wanted), "GPU mode requires working actual MultiMesh transform readback")


func _check_factories() -> void:
	var carpet := GrassField._card_tuft()
	var other := GrassField._card_tuft()
	var tuft := GroundCover._tuft()
	_check(carpet != other and carpet != tuft, "Each factory call needs an independent mesh")
	_check_mesh(carpet)
	_check_mesh(tuft)
	_check(carpet.surface_get_material(0) == null, "Static material must not leak into the shared pure factory")
	var material := tuft.surface_get_material(0) as ShaderMaterial
	_check_photo_material(material, STATIC)
	if material != null:
		_check(is_equal_approx(float(material.get_shader_parameter("fade_out_at")), 55.0), "Static per-tree fade distance")
		_check(is_equal_approx(float(material.get_shader_parameter("fade_out_width")), 14.0), "Static fade width")
	_check_texture(ALBEDO, false)
	_check_texture(ALPHA, true)


func _check_mesh(mesh: ArrayMesh) -> void:
	_check(mesh != null and mesh.get_surface_count() == 1, "One card mesh surface required")
	if mesh == null or mesh.get_surface_count() != 1:
		return
	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var atlas: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	_check(vertices.size() == 12 and indices.size() == 18, "Three cards must use six indexed triangles")
	_check(normals.size() == vertices.size() and uv.size() == vertices.size() and atlas.size() == vertices.size(), "Missing vertex attributes")
	if normals.size() != vertices.size() or uv.size() != vertices.size() or atlas.size() != vertices.size():
		return
	var roots := 0
	var tips := 0
	for i in vertices.size():
		var vertex := vertices[i]
		_check(vertex.is_finite(), "Non-finite card vertex")
		# Godot4.5.2 packs normals: UP decodes with about1/65535 Z error.
		_check(normals[i].distance_to(Vector3.UP) < 0.00002, "Grass lighting normal must face up")
		_check(uv[i].x in [0.0, 1.0] and uv[i].y in [0.0, 1.0], "Card logical UV corners")
		_check(absf(vertex.y - uv[i].y * HEIGHT) < 0.00001, "Logical root/tip UV must follow physical height")
		_check(absf(Vector2(vertex.x, vertex.z).length() - HALF_WIDTH) < 0.00001, "Fixed grass-card width changed")
		var expected := Vector2(lerpf(ATLAS_MIN.x, ATLAS_MAX.x, uv[i].x), lerpf(ATLAS_MAX.y, ATLAS_MIN.y, uv[i].y))
		_check(atlas[i].is_equal_approx(expected), "Atlas crop or vertical root/tip orientation changed")
		roots += int(is_zero_approx(vertex.y))
		tips += int(is_equal_approx(vertex.y, HEIGHT))
	_check(roots == 6 and tips == 6, "All three cards need two grounded roots and two tips")
	var bounds := mesh.get_aabb()
	_check(absf(bounds.position.y) < 0.00001 and absf(bounds.size.y - HEIGHT) < 0.00001, "Mesh base or height bounds changed")
	if indices.size() != 18:
		return
	for i in range(0, indices.size(), 3):
		var valid := true
		for j in 3:
			valid = valid and indices[i + j] >= 0 and indices[i + j] < vertices.size()
		_check(valid, "Triangle index outside vertex buffer")
		if valid:
			var area := (vertices[indices[i + 1]] - vertices[indices[i]]).cross(vertices[indices[i + 2]] - vertices[indices[i]]).length() * 0.5
			_check(absf(area - HALF_WIDTH * HEIGHT) < 0.00001, "Collapsed or distorted card triangle")


func _check_texture(path: String, mask: bool) -> void:
	var texture := load(path) as Texture2D
	_check(texture != null, "Missing photo texture: " + path)
	if texture == null:
		return
	_check(texture.get_size() == Vector2(2048, 2048), "Photo atlas resolution changed")
	var image := texture.get_image()
	_check(image != null, "Imported photo texture has no readable image")
	if image == null:
		return
	_check(image.has_mipmaps() and image.get_mipmap_count() == 11, "2K texture needs its full mip chain")
	var config := ConfigFile.new()
	var loaded := config.load(path + ".import")
	_check(loaded == OK, "Photo texture import configuration is missing")
	if loaded == OK:
		_check(int(config.get_value("params", "compress/mode", -1)) == 0, "Photo import must remain lossless")
		_check(config.get_value("params", "mipmaps/generate", false) == true, "Photo mip generation disabled")
		_check(int(config.get_value("params", "mipmaps/limit", 0)) == -1, "Photo mip chain limited")
		_check(config.get_value("params", "process/premult_alpha", true) == false, "Photo alpha must not be premultiplied")
		_check(config.get_value("params", "process/fix_alpha_border", true) == false, "Original atlas edges must stay unchanged")
	if mask:
		if image.is_compressed():
			_check(image.decompress() == OK, "Cannot read imported alpha samples")
			if image.is_compressed():
				return
		var visible := 0
		var background := 0
		# Exercise the actual sampled clump region, not the unused atlas cells.
		for y in range(16):
			for x in range(24):
				var p := Vector2(lerpf(ATLAS_MIN.x, ATLAS_MAX.x, (x + 0.5) / 24.0), lerpf(ATLAS_MIN.y, ATLAS_MAX.y, (y + 0.5) / 16.0))
				var alpha := image.get_pixel(int(p.x * image.get_width()), int(p.y * image.get_height())).r
				visible += int(alpha >= 0.5)
				background += int(alpha < 0.5)
		_check(visible > 0 and background > 0, "Alpha crop cannot be empty or an opaque rectangular sheet")


func _check_photo_material(material: ShaderMaterial, shader_path: String) -> void:
	_check(material != null and material.shader != null, "Missing photo material/shader")
	if material == null or material.shader == null:
		return
	_check(material.shader.resource_path == shader_path, "Static/carpet shader binding crossed")
	for pair in [["grass_albedo", ALBEDO], ["grass_alpha", ALPHA]]:
		var texture := material.get_shader_parameter(pair[0]) as Texture2D
		_check(texture != null and texture.resource_path == pair[1], "Wrong photo sampler binding: " + str(pair[0]))


func _check_static_placement() -> void:
	var spots: Array[Transform3D] = [
		Transform3D(Basis(Vector3.UP, 0.4).scaled(Vector3(0.8, 1.1, 0.8)), Vector3(1, 2, 3)),
		Transform3D(Basis(Vector3.UP, 2.0), Vector3(101, -3, 3)),
		Transform3D(Basis(Vector3.UP, 1.2).scaled(Vector3(1.0, 0.7, 1.0)), Vector3(2, 4, 5)),
		Transform3D(Basis(Vector3.UP, -0.7), Vector3(-30, 0.5, 2)),
	]
	var parent := Node3D.new()
	var tuft := GroundCover._tuft()
	var variants: Array[Mesh] = [tuft]
	GroundCover._scatter(parent, variants, spots, 79.0, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	_check(parent.get_child_count() == 3, "Static fixture block count changed")
	var missing: Array[Transform3D] = spots.duplicate()
	var total_instances := 0
	for child in parent.get_children():
		var instance := child as MultiMeshInstance3D
		_check(instance != null and instance.multimesh != null, "Missing static MultiMesh")
		if instance == null or instance.multimesh == null:
			continue
		_check(instance.transform.is_equal_approx(Transform3D.IDENTITY), "Static transforms must not be applied twice")
		_check(instance.multimesh.mesh == tuft, "Static clump geometry binding changed")
		_check(instance.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "Static grass added shadow casters")
		_check(is_equal_approx(instance.visibility_range_end, 79.0), "Static range padding changed")
		total_instances += instance.multimesh.instance_count
		if check_placement:
			for i in instance.multimesh.instance_count:
				var actual := instance.multimesh.get_instance_transform(i)
				var match_index := -1
				for j in missing.size():
					if actual.is_equal_approx(missing[j]):
						match_index = j
						break
				_check(match_index >= 0, "Static placement duplicated or transform changed")
				if match_index >= 0:
					missing.remove_at(match_index)
	_check(total_instances == spots.size(), "Static instance count changed")
	if check_placement:
		_check(missing.is_empty(), "Static placement lost one or more input tufts")
	parent.free()


func _check_carpet(views: int) -> void:
	var expected: Array = HIGH if views == 1 else (MEDIUM if views == 2 else LOW)
	var ground := Image.create(2, 2, false, Image.FORMAT_RGBAF)
	ground.fill(Color(0, 10, 1, 1))
	var parent := Node3D.new()
	GrassField.build(parent, ground, Vector2(-4, 6), "auto", views)
	_check(parent.get_child_count() == expected.size(), "Auto detail grid count changed for views " + str(views))
	var shared_grass: Mesh
	for i in mini(parent.get_child_count(), expected.size()):
		var instance := parent.get_child(i) as MultiMeshInstance3D
		_check(instance != null and instance.multimesh != null, "Missing carpet MultiMesh")
		if instance == null or instance.multimesh == null:
			continue
		var spec: Array = expected[i]
		var kind: int = spec[0]
		var cell: float = spec[1]
		var radius: float = spec[3]
		var side := int(ceil(2.0 * radius / cell))
		var mm := instance.multimesh
		var material := instance.material_override as ShaderMaterial
		_check(instance.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "Carpet added shadow casters")
		_check(instance.custom_aabb.has_point(Vector3(10000, 1000, 10000)) and instance.custom_aabb.has_point(Vector3(-10000, -1000, -10000)), "Camera-wrapping grid can be culled near world origin")
		_check(mm.instance_count == side * side, "Carpet placement density changed")
		_check(material != null and material.shader != null, "Carpet material missing")
		if material == null or material.shader == null:
			continue
		for pair in [["kind", kind], ["cell", cell], ["inner", spec[2]], ["radius", radius], ["grow", spec[4]], ["span", side * cell]]:
			_check(is_equal_approx(float(material.get_shader_parameter(pair[0])), float(pair[1])), "Carpet grid setting changed: " + str(pair[0]))
		if kind == 0:
			_check_photo_material(material, CARPET)
			if shared_grass == null:
				shared_grass = mm.mesh
				_check_mesh(mm.mesh as ArrayMesh)
			else:
				_check(mm.mesh == shared_grass, "Near/far grass rings must share the same card silhouette")
		else:
			_check(material.shader.resource_path == SHRUB, "Photo material leaked onto shrubs")
			_check(mm.mesh != shared_grass, "Shrubs replaced by grass cards")
		if mm.instance_count != side * side or not check_placement:
			continue
		var half := floori(float(side) * 0.5)
		for position in [Vector2i.ZERO, Vector2i(side - 1, 0), Vector2i(0, side - 1), Vector2i(side - 1, side - 1), Vector2i(half, half)]:
			var actual := mm.get_instance_transform(position.y * side + position.x)
			var wanted := Vector3((position.x - half) * cell, 0, (position.y - half) * cell)
			_check(actual.origin.is_equal_approx(wanted) and actual.basis.is_equal_approx(Basis.IDENTITY), "Carpet grid spacing/origin changed")
	parent.free()


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
