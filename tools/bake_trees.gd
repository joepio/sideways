extends SceneTree
## Builds the tree meshes from the raw arrays tools/thin_tree.py writes:
##   godot --headless --path . --script res://tools/bake_trees.gd -- /tmp/trees_raw
## Saves assets/trees/fir_<a|b|c>_<near|mid>.res, one surface per material.
## UV surfaces get MikkTSpace tangents without changing their indexed geometry.
## Trunks with no UV area keep their existing generated-basis fallback.

const ORDER := ["trunk_a", "trunk_b", "trunk_c", "bark", "dead_branches", "twig"]


func _initialize() -> void:
	var dir: String = OS.get_cmdline_user_args()[0]
	var manifest: Array = JSON.parse_string(FileAccess.get_file_as_string(dir + "/manifest.json"))
	var meshes := {}
	for part in ORDER:
		for m in manifest:
			if m.material != part:
				continue
			var key := "fir_%s_%s" % [m.tree, m.lod]
			if not meshes.has(key):
				meshes[key] = ArrayMesh.new()
			var mesh: ArrayMesh = meshes[key]
			var f := FileAccess.open("%s/%s.bin" % [dir, m.name], FileAccess.READ)
			var nv: int = m.verts
			var verts := f.get_buffer(nv * 12).to_float32_array()
			var normals := f.get_buffer(nv * 12).to_float32_array()
			var uvs := f.get_buffer(nv * 8).to_float32_array()
			var idx := f.get_buffer(int(m.tris) * 12).to_int32_array()
			var arrays := []
			arrays.resize(Mesh.ARRAY_MAX)
			var v3 := PackedVector3Array()
			var n3 := PackedVector3Array()
			var t2 := PackedVector2Array()
			v3.resize(nv)
			n3.resize(nv)
			t2.resize(nv)
			for i in nv:
				v3[i] = Vector3(verts[i * 3], verts[i * 3 + 1], verts[i * 3 + 2])
				n3[i] = Vector3(normals[i * 3], normals[i * 3 + 1], normals[i * 3 + 2]).normalized()
				t2[i] = Vector2(uvs[i * 2], uvs[i * 2 + 1])
			# glTF winds counter-clockwise, Godot clockwise.
			for i in range(0, idx.size(), 3):
				var tmp := idx[i + 1]
				idx[i + 1] = idx[i + 2]
				idx[i + 2] = tmp
			arrays[Mesh.ARRAY_VERTEX] = v3
			arrays[Mesh.ARRAY_NORMAL] = n3
			arrays[Mesh.ARRAY_TEX_UV] = t2
			arrays[Mesh.ARRAY_INDEX] = idx
			if not add_uv_tangents(arrays, str(m.name)):
				# All meshes are saved after this loop: a failed check must not
				# leave a partially rebaked set of assets on disk.
				quit(1)
				return
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			mesh.surface_set_material(mesh.get_surface_count() - 1, _material(part))
			mesh.surface_set_name(mesh.get_surface_count() - 1, part)
	for key in meshes:
		var path := "res://assets/trees/%s.res" % key
		ResourceSaver.save(meshes[key], path, ResourceSaver.FLAG_COMPRESS)
		print("saved ", path, " surfaces ", meshes[key].get_surface_count())
	quit()


## Adds only ARRAY_TANGENT. In particular, do not replace a mesh using
## SurfaceTool.commit(): that path discards its LOD indices and materials.
## This also makes the generator usable for a tangent-only offline repair;
## a caller rebuilding an existing mesh must pass through its original LODs.
static func add_uv_tangents(arrays: Array, label := "surface") -> bool:
	if arrays.size() != Mesh.ARRAY_MAX:
		push_error("Invalid tree array layout: %s" % label)
		return false
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	if vertices.is_empty() or normals.size() != vertices.size() or uv.size() != vertices.size() or indices.is_empty() or indices.size() % 3 != 0:
		push_error("Invalid indexed tree arrays: %s" % label)
		return false
	for index in indices:
		if index < 0 or index >= vertices.size():
			push_error("Tree index outside vertex array: %s" % label)
			return false
	var has_uv_area := false
	for triangle in range(0, indices.size(), 3):
		var a := indices[triangle]
		var b := indices[triangle + 1]
		var c := indices[triangle + 2]
		var u := uv[b] - uv[a]
		var v := uv[c] - uv[a]
		if absf(u.cross(v)) > 1e-10 and (vertices[b] - vertices[a]).cross(vertices[c] - vertices[a]).length_squared() > 1e-16:
			has_uv_area = true
			break
	if not has_uv_area:
		# trunk_c uses a cylindrical UV in bark.gdshader; its source UVs
		# are all zero. They cannot define a meaningful tangent frame.
		print("tangents: retained fallback for ", label, " (no UV area)")
		return true
	var st := SurfaceTool.new()
	st.create_from_arrays(arrays, Mesh.PRIMITIVE_TRIANGLES)
	st.generate_tangents()
	var generated := st.commit_to_arrays()
	for channel in Mesh.ARRAY_MAX:
		if channel != Mesh.ARRAY_TANGENT and generated[channel] != arrays[channel]:
			push_error("Tangent generation changed tree array %d: %s" % [channel, label])
			return false
	if generated[Mesh.ARRAY_TANGENT] == null:
		push_error("Tangent generation produced no data: %s" % label)
		return false
	var tangents: PackedFloat32Array = generated[Mesh.ARRAY_TANGENT]
	if tangents.size() != vertices.size() * 4:
		push_error("Tangent generation changed vertex count: %s" % label)
		return false
	for i in vertices.size():
		var t := Vector3(tangents[i * 4], tangents[i * 4 + 1], tangents[i * 4 + 2])
		var handedness := tangents[i * 4 + 3]
		if not t.is_finite() or not is_finite(handedness) or absf(t.length_squared() - 1.0) > 0.01 or absf(t.dot(normals[i])) > 0.01 or absf(absf(handedness) - 1.0) > 0.01:
			push_error("Invalid tangent at tree vertex %d: %s" % [i, label])
			return false
	arrays[Mesh.ARRAY_TANGENT] = tangents
	return true


var _cache := {}


func _material(part: String) -> Material:
	if _cache.has(part):
		return _cache[part]
	var m: Material
	if part == "twig":
		var sm := ShaderMaterial.new()
		sm.shader = load("res://src/shaders/foliage.gdshader")
		sm.set_shader_parameter("albedo_tex", load("res://assets/trees/twig_albedo.png"))
		sm.set_shader_parameter("normal_tex", load("res://assets/trees/twig_normal.jpg"))
		m = sm
	else:
		var tex := "bark" if part in ["bark", "dead_branches"] else ("trunk_a" if part == "trunk_c" else part)
		var std := StandardMaterial3D.new()
		std.albedo_texture = load("res://assets/trees/%s_albedo.jpg" % tex)
		std.normal_enabled = true
		std.normal_texture = load("res://assets/trees/%s_normal.jpg" % tex)
		std.roughness = 0.95
		if part == "trunk_c":
			std.uv1_triplanar = true
			std.uv1_scale = Vector3(1.5, 0.5, 1.5)
		std.cull_mode = BaseMaterial3D.CULL_DISABLED if part != "trunk_a" and part != "trunk_b" else BaseMaterial3D.CULL_BACK
		m = std
	_cache[part] = m
	return m
