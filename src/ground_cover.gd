class_name GroundCover
## Everything small on the forest floor: grass tufts along the verge, ferns,
## mossy rocks and old stumps (Poly Haven, CC0). Like the trees they are
## MultiMeshes per block with visibility ranges; grass dissolves out.

const BLOCK := 24.0 ## for the grass; the rest uses blocks a third of its reach
const GRASS_END := 55.0
const FERN_END := 90.0
const PROP_END := 220.0

static var _mesh_cache := {}


static func build(parent: Node3D, grass: Array[Transform3D], ferns: Array[Transform3D], rocks: Array[Transform3D], stumps: Array[Transform3D]) -> void:
	var tuft := _tuft()
	_scatter(parent, [tuft], grass, GRASS_END + BLOCK, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	_scatter(parent, _meshes("res://assets/props/fern_02/fern_02.gltf"), ferns, FERN_END, GeometryInstance3D.SHADOW_CASTING_SETTING_ON)
	_scatter(parent, _meshes("res://assets/props/rock_moss_set_01/rock_moss_set_01.gltf"), rocks, PROP_END, GeometryInstance3D.SHADOW_CASTING_SETTING_ON)
	_scatter(parent, _meshes("res://assets/props/tree_stump_01/tree_stump_01.gltf"), stumps, PROP_END, GeometryInstance3D.SHADOW_CASTING_SETTING_ON)


## Spots are shared out over the variants and grouped per block.
static func _scatter(parent: Node3D, variants: Array[Mesh], spots: Array[Transform3D], end: float, shadow: int) -> void:
	if variants.is_empty() or spots.is_empty():
		return
	# Each MultiMesh is culled per view and per shadow split, so they should
	# not be smaller than they need to be.
	var block := clampf(end / 3.0, BLOCK, 96.0)
	var groups := {}
	for i in spots.size():
		var o := spots[i].origin
		var key := Vector3i(floori(o.x / block), floori(o.z / block), (i * 7919 + 3) % variants.size())
		if not groups.has(key):
			groups[key] = []
		groups[key].append(spots[i])
	for key in groups:
		var list: Array = groups[key]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = variants[key.z]
		mm.instance_count = list.size()
		for j in list.size():
			mm.set_instance_transform(j, list[j])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.visibility_range_end = end
		mmi.cast_shadow = shadow as GeometryInstance3D.ShadowCastingSetting
		mmi.set_meta("strip", "cover")
		parent.add_child(mmi)


## The meshes in an imported glTF, each with its node's transform baked in
## so a set of rocks comes out as separate rocks standing on their origin.
static func _meshes(path: String) -> Array[Mesh]:
	if _mesh_cache.has(path):
		return _mesh_cache[path]
	var out: Array[Mesh] = []
	var scene: PackedScene = load(path)
	if scene == null:
		return out
	var root := scene.instantiate()
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		if n is MeshInstance3D and n.mesh:
			var mesh: Mesh = n.mesh
			# Centre it on its own footprint, base at y = 0.
			var aabb := mesh.get_aabb()
			var am := ArrayMesh.new()
			for s in mesh.get_surface_count():
				var shift := Transform3D(Basis(), -Vector3(aabb.get_center().x, aabb.position.y, aabb.get_center().z))
				# Keep the importer's vertex order and LOD indices. Rebuilding
				# through SurfaceTool discarded every LOD, drawing even a tiny
				# distant stump with all 41k triangles in each view/shadow pass.
				var arrays := mesh.surface_get_arrays(s)
				var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				for v in verts.size():
					verts[v] = shift * verts[v]
				arrays[Mesh.ARRAY_VERTEX] = verts
				am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], _lods(mesh, s))
				am.surface_set_material(s, mesh.surface_get_material(s))
			out.append(am)
	root.free()
	_mesh_cache[path] = out
	return out


## RenderingServer stores LOD indices packed with the source surface's
## index width. Translation changes neither their order nor their errors.
static func _lods(mesh: Mesh, surface: int) -> Dictionary:
	var data := RenderingServer.mesh_get_surface(mesh.get_rid(), surface)
	var out := {}
	for lod in data.get("lods", []):
		var bytes: PackedByteArray = lod.index_data
		var indices := PackedInt32Array()
		if int(data.vertex_count) <= 65536:
			indices.resize(bytes.size() / 2)
			for i in indices.size():
				indices[i] = bytes.decode_u16(i * 2)
		else:
			indices = bytes.to_int32_array()
		out[float(lod.edge_length)] = indices
	return out


## One tuft: a dozen tapered blades leaning out from the root.
static func _tuft() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for b in 26:
		var a := rng.randf() * TAU
		var lean := rng.randf_range(0.1, 0.45)
		var h := rng.randf_range(0.14, 0.38)
		var w := rng.randf_range(0.014, 0.028)
		var base := Vector3(cos(a), 0.0, sin(a)) * rng.randf_range(0.0, 0.16)
		var out := Vector3(cos(a), 0.0, sin(a))
		var side := Vector3(-out.z, 0.0, out.x) * w
		var mid := base + out * lean * h * 0.4 + Vector3.UP * h * 0.55
		var tip := base + out * lean * h + Vector3.UP * h
		var dry := rng.randf()
		var root_c := Color(0.07, 0.1, 0.035)
		var mid_c := Color(0.2, 0.28, 0.08).lerp(Color(0.34, 0.33, 0.16), dry * 0.6)
		var tip_c := Color(0.36, 0.42, 0.16).lerp(Color(0.55, 0.5, 0.3), dry)
		var nrm := Vector3.UP
		var quads := [[base - side, base + side, mid + side * 0.7, mid - side * 0.7, root_c, mid_c, 0.0, 0.55]]
		for q in quads:
			_quad(st, q[0], q[1], q[2], q[3], q[4], q[5], q[6], q[7], nrm)
		# The tip.
		st.set_normal(nrm)
		st.set_color(mid_c)
		st.set_uv(Vector2(0.0, 0.55))
		st.add_vertex(mid - side * 0.7)
		st.set_uv(Vector2(1.0, 0.55))
		st.add_vertex(mid + side * 0.7)
		st.set_color(tip_c)
		st.set_uv(Vector2(0.5, 1.0))
		st.add_vertex(tip)
	st.index()
	var mesh := st.commit()
	var mat := ShaderMaterial.new()
	mat.shader = load("res://src/shaders/grass.gdshader")
	mat.set_shader_parameter("fade_out_at", GRASS_END)
	mat.set_shader_parameter("fade_out_width", 14.0)
	mesh.surface_set_material(0, mat)
	return mesh


static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, c0: Color, c1: Color, v0: float, v1: float, n: Vector3) -> void:
	st.set_normal(n)
	for p in [[a, c0, Vector2(0, v0)], [b, c0, Vector2(1, v0)], [c, c1, Vector2(1, v1)], [a, c0, Vector2(0, v0)], [c, c1, Vector2(1, v1)], [d, c1, Vector2(0, v1)]]:
		st.set_color(p[1])
		st.set_uv(p[2])
		st.add_vertex(p[0])
