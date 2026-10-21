extends SceneTree
## Separate authored-pine crown reproduction. Never writes runtime assets.
## godot --headless --path . --script res://tools/build_pine_crowns.gd -- --out-dir res://build/pine-crowns-review
## The output directory must not exist. See pine_crown_data/README.md.

const BAKER := preload("res://tools/bake_trees.gd")
const DATA_DIR := "res://tools/pine_crown_data"
const MANIFEST_PATH := DATA_DIR + "/manifest.json"
const FOLIAGE_PATH := "res://src/shaders/foliage.gdshader"
const VARIANTS := ["a", "b", "c"]
const LODS := ["near", "mid"]
const SURFACE_NAMES := ["trunk_a", "trunk_b", "trunk_c", "bark", "dead_branches", "twig"]
var output_dir := ""
var output_created := false
var report: Dictionary = {"status": "preparing", "trees": [], "visual_validation": false, "input_sha256": {}}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var version: Dictionary = Engine.get_version_info()
	if str(version.get("string", "")).find("4.5.2") != 0:
		_fail("This packed-surface workflow is validated for Godot 4.5.2 only")
		return
	var args := OS.get_cmdline_user_args()
	if args.size() != 2 or args[0] != "--out-dir" or not _valid_output(args[1]):
		_fail("Expected --out-dir res://build/<new-simple-directory-name>; existing output is refused")
		return
	output_dir = args[1]
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_PATH))
	if not parsed is Dictionary:
		_fail("Missing or invalid portable manifest")
		return
	var manifest: Dictionary = parsed
	if manifest.get("schema_version", 0) != 1 or not manifest.get("variants") is Dictionary or not manifest.get("textures") is Dictionary:
		_fail("Unsupported portable manifest schema")
		return
	report["engine"] = Engine.get_version_info().string
	report["manifest_sha256"] = FileAccess.get_sha256(MANIFEST_PATH)
	report["foliage_shader_sha256"] = FileAccess.get_sha256(FOLIAGE_PATH)
	for texture_name in ["albedo", "normal"]:
		var path := "res://assets/trees/authored_pine_%s.png" % texture_name
		var texture_spec: Dictionary = manifest.textures.get(texture_name, {})
		if texture_spec.get("path", "") != path or not FileAccess.file_exists(path) or FileAccess.get_sha256(path) != texture_spec.get("sha256", ""):
			_fail("Missing/mismatched pinned authored texture: " + path)
			return
		report.input_sha256[path] = FileAccess.get_sha256(path)
	var albedo := load("res://assets/trees/authored_pine_albedo.png") as Texture2D
	var normal := load("res://assets/trees/authored_pine_normal.png") as Texture2D
	if albedo == null or normal == null:
		_fail("Import the pinned authored albedo/normal textures first")
		return
	var pending: Array[Dictionary] = []
	for variant in VARIANTS:
		var spec: Dictionary = manifest.variants.get(variant, {})
		if spec.get("raw_file", "") != "raw/%s_crown.bin" % variant or not spec.get("geometry") is Dictionary or not spec.get("target_bounds") is Dictionary:
			_fail("Invalid raw crown manifest entry: " + variant)
			return
		var arrays := _crown_arrays(spec)
		if arrays.is_empty():
			return
		var original_near := load("res://assets/trees/fir_%s_near.res" % variant) as ArrayMesh
		if original_near == null or not _bounds_match(original_near.get_aabb(), spec.target_bounds):
			_fail("Near bounds differ from the recorded fit; refit raw data before building " + variant)
			return
		for lod in LODS:
			var filename := "fir_%s_%s.res" % [variant, lod]
			var path := "res://assets/trees/" + filename
			report.input_sha256[path] = FileAccess.get_sha256(path)
			var original := load(path) as ArrayMesh
			var result := _replace_crown(original, arrays, albedo, normal, variant, lod)
			if result == null or not _bounds_match(result.get_aabb(), spec.target_bounds):
				_fail("Unsupported material/surface or candidate preservation/bounds check failed: " + filename)
				return
			pending.append({"path": output_dir.path_join(filename), "mesh": result})
	# All six meshes pass before any output directory or resource is created.
	if not _valid_output(output_dir) or DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output_dir)) != OK:
		_fail("Cannot create fresh candidate output directory")
		return
	output_created = true
	for item in pending:
		var error := ResourceSaver.save(item.mesh, item.path, ResourceSaver.FLAG_COMPRESS)
		if error != OK:
			_fail("Candidate save failed: " + str(item.path))
			return
		print("candidate crown saved ", item.path)
	report["output_sha256"] = {}
	for item in pending:
		report.output_sha256[str(item.path).get_file()] = FileAccess.get_sha256(item.path)
	report.status = "built; no runtime assets changed; paired impostors and visual review required"
	report["near_mid_crown_arrays_identical"] = true
	if not _save_report():
		_fail("Could not write candidate build report")
		return
	print("CANDIDATE ONLY: current wood preserved; inspect old dead branches and rebake paired impostors before promotion")
	quit(0)


func _valid_output(path: String) -> bool:
	if not path.begins_with("res://build/"):
		return false
	var simple := path.trim_prefix("res://build/")
	var pattern := RegEx.new()
	if pattern.compile("^[A-Za-z0-9][A-Za-z0-9_-]*$") != OK or pattern.search(simple) == null:
		return false
	var root_dir := DirAccess.open("res://")
	if root_dir == null or root_dir.is_link("build"):
		return false
	var build_dir := DirAccess.open("res://build")
	if build_dir != null and build_dir.is_link(simple):
		return false
	return not DirAccess.dir_exists_absolute(path) and not FileAccess.file_exists(path)


func _compatible_foliage(material: ShaderMaterial) -> bool:
	if material.shader == null or material.shader.resource_path != FOLIAGE_PATH:
		return false
	var code := material.shader.code
	for required in ["uniform sampler2D albedo_tex", "uniform sampler2D normal_tex", "uniform float alpha_cut", "texture(albedo_tex, UV)", "texture(normal_tex, UV)", "ALPHA_SCISSOR_THRESHOLD = alpha_cut", "cull_disabled"]:
		if not code.contains(required):
			return false
	# This crown has authored atlas UVs: wind must use geometry height, not UV.y.
	var vertex_start := code.find("void vertex()")
	var fragment_start := code.find("void fragment()")
	if vertex_start < 0 or fragment_start <= vertex_start:
		return false
	var vertex_code := code.substr(vertex_start, fragment_start - vertex_start)
	return vertex_code.contains("VERTEX.y") and not vertex_code.contains("UV")


func _bounds_match(aabb: AABB, target: Dictionary) -> bool:
	var radius := maxf(maxf(absf(aabb.position.x), absf(aabb.end.x)), maxf(absf(aabb.position.z), absf(aabb.end.z)))
	return absf(aabb.end.y - float(target.height)) < 0.0001 and absf(radius - float(target.radius)) < 0.0001 and absf(maxf(aabb.end.y, 4.0 * radius) - float(target.camera_size)) < 0.0001


func _crown_arrays(spec: Dictionary) -> Array:
	var path := DATA_DIR.path_join(str(spec.raw_file))
	if FileAccess.get_sha256(path) != str(spec.raw_sha256):
		_fail("Raw crown hash mismatch: " + path)
		return []
	var file := FileAccess.open(path, FileAccess.READ)
	var count: int = spec.geometry.vertices
	var triangles: int = spec.geometry.triangles
	if file == null or count != 1088 or triangles != 1088 or file.get_length() != count * 32 + triangles * 12:
		_fail("Unexpected raw crown layout")
		return []
	var positions := file.get_buffer(count * 12).to_float32_array()
	var normals := file.get_buffer(count * 12).to_float32_array()
	var uvs := file.get_buffer(count * 8).to_float32_array()
	var indices := file.get_buffer(triangles * 12).to_int32_array()
	var p := PackedVector3Array()
	var n := PackedVector3Array()
	var uv := PackedVector2Array()
	p.resize(count)
	n.resize(count)
	uv.resize(count)
	for i in count:
		p[i] = Vector3(positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2])
		n[i] = Vector3(normals[i * 3], normals[i * 3 + 1], normals[i * 3 + 2])
		uv[i] = Vector2(uvs[i * 2], uvs[i * 2 + 1])
		if not p[i].is_finite() or not n[i].is_finite() or not uv[i].is_finite() or absf(n[i].length_squared() - 1.0) > 0.01:
			_fail("Non-finite crown data or invalid unit normal")
			return []
	for i in range(0, indices.size(), 3):
		var swap := indices[i + 1]
		indices[i + 1] = indices[i + 2]
		indices[i + 2] = swap
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = p
	arrays[Mesh.ARRAY_NORMAL] = n
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_INDEX] = indices
	if not BAKER.add_uv_tangents(arrays, path):
		_fail("Candidate tangent generation failed")
		return []
	return arrays


func _replace_crown(original: ArrayMesh, arrays: Array, albedo: Texture2D, normal: Texture2D, variant: String, lod: String) -> ArrayMesh:
	if original == null or original.get_blend_shape_count() != 0 or original.shadow_mesh != null:
		return null
	var source_surfaces: Array = original.get("_surfaces")
	var surfaces: Array = source_surfaces.duplicate(true)
	var seen_names: Array[String] = []
	if source_surfaces.size() != original.get_surface_count():
		return null
	var twig_count := 0
	var entry: Dictionary = {"variant": variant, "lod": lod, "dead_branch_check": "requires visual preview"}
	for i in original.get_surface_count():
		var name := original.surface_get_name(i)
		if name not in SURFACE_NAMES or name in seen_names or original.surface_get_primitive_type(i) != Mesh.PRIMITIVE_TRIANGLES:
			return null
		seen_names.append(name)
		if name == "twig":
			var previous := original.surface_get_material(i) as ShaderMaterial
			if previous == null or not _compatible_foliage(previous):
				return null
			var material := previous.duplicate() as ShaderMaterial
			material.set_shader_parameter("albedo_tex", albedo)
			material.set_shader_parameter("normal_tex", normal)
			material.set_shader_parameter("alpha_cut", 0.42)
			var twig := ArrayMesh.new()
			twig.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			twig.surface_set_name(0, "twig")
			twig.surface_set_material(0, material)
			var data: Array = twig.get("_surfaces")
			surfaces[i] = data[0]
			var old_arrays := original.surface_get_arrays(i)
			entry["old_twig_vertices"] = old_arrays[Mesh.ARRAY_VERTEX].size()
			entry["old_twig_triangles"] = int(old_arrays[Mesh.ARRAY_INDEX].size() / 3)
			entry["new_twig_vertices"] = arrays[Mesh.ARRAY_VERTEX].size()
			entry["new_twig_triangles"] = int(arrays[Mesh.ARRAY_INDEX].size() / 3)
			twig_count += 1
		elif name == "dead_branches":
			var old_arrays := original.surface_get_arrays(i)
			var dead: PackedVector3Array = old_arrays[Mesh.ARRAY_VERTEX]
			var crown: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var box := AABB(crown[0], Vector3.ZERO)
			for point in crown:
				box = box.expand(point)
			var outside := 0
			for point in dead:
				if point.y >= box.position.y and not box.grow(0.02).has_point(point):
					outside += 1
			entry["dead_branch_vertices_above_crown_base_outside_crown_aabb"] = outside
	if twig_count != 1 or source_surfaces.size() < 2:
		return null
	var result := ArrayMesh.new()
	result.resource_name = original.resource_name
	result.custom_aabb = original.custom_aabb
	result.lightmap_size_hint = original.lightmap_size_hint
	for key in original.get_meta_list():
		result.set_meta(key, original.get_meta(key))
	result.set("_surfaces", surfaces)
	if result.get_surface_count() != original.get_surface_count() or result.get("_surfaces") != surfaces:
		return null
	var actual: Array = result.get("_surfaces")
	for i in original.get_surface_count():
		if original.surface_get_name(i) != "twig" and actual[i] != source_surfaces[i]:
			return null
	entry["non_twig_packed_dictionaries_equal"] = true
	entry["surface_names"] = seen_names
	report.trees.append(entry)
	return result


func _save_report() -> bool:
	if not output_created:
		return false
	var file := FileAccess.open(output_dir.path_join("build-report.json"), FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(report, "\t") + "\n")
	file.close()
	return true


func _fail(message: String) -> void:
	push_error(message)
	report.status = "failed; any partial files are candidates only"
	report["error"] = message
	if output_created:
		_save_report()
	quit(1)
