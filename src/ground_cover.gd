class_name GroundCover
## Everything small on the forest floor: grass tufts along the verge, ferns,
## mossy rocks and old stumps (Poly Haven, CC0). Like the trees they are
## MultiMeshes per block with visibility ranges; grass dissolves out.

const BLOCK := 24.0 ## for the grass; the rest uses blocks a third of its reach
const GRASS_END := 55.0
const FERN_END := 90.0
const PROP_END := 220.0
const COLLISION_BLOCK := 24.0

static var _mesh_cache := {}
static var _collision_cache := {}


static func build(parent: Node3D, grass: Array[Transform3D], ferns: Array[Transform3D], rocks: Array[Transform3D], stumps: Array[Transform3D]) -> void:
	var tuft := _tuft()
	_scatter(parent, [tuft], grass, GRASS_END + BLOCK, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	_scatter(parent, _meshes("res://assets/props/fern_02/fern_02.gltf"), ferns, FERN_END, GeometryInstance3D.SHADOW_CASTING_SETTING_ON)
	var rock_meshes := _meshes("res://assets/props/rock_moss_set_01/rock_moss_set_01.gltf")
	var stump_meshes := _meshes("res://assets/props/tree_stump_01/tree_stump_01.gltf")
	_scatter(parent, rock_meshes, rocks, PROP_END, GeometryInstance3D.SHADOW_CASTING_SETTING_ON)
	_scatter(parent, stump_meshes, stumps, PROP_END, GeometryInstance3D.SHADOW_CASTING_SETTING_ON)
	_colliders(parent, rock_meshes, rocks, "RockColliders")
	_colliders(parent, stump_meshes, stumps, "StumpColliders")


## Solid props use the same variant and complete transform as _scatter. The
## collision nodes remain active when render LODs or Streamer hide the mesh.
static func _colliders(parent: Node3D, variants: Array[Mesh], spots: Array[Transform3D], label: String) -> void:
	if variants.is_empty() or spots.is_empty():
		return
	var shapes: Array[ConvexPolygonShape3D] = []
	for mesh in variants:
		shapes.append(_solid_shape(mesh))
	var root := Node3D.new()
	root.name = label
	parent.add_child(root)
	var blocks := {}
	for i in spots.size():
		var xf := spots[i]
		var key := Vector2i(floori(xf.origin.x / COLLISION_BLOCK), floori(xf.origin.z / COLLISION_BLOCK))
		if not blocks.has(key):
			var body := StaticBody3D.new()
			body.collision_layer = 1 # Both tyre casts and the chase-camera sweep.
			body.collision_mask = 1
			body.set_meta("surface", Surfaces.DIRT)
			root.add_child(body)
			blocks[key] = body
		var shape := CollisionShape3D.new()
		# Rock placement scales after an arbitrary rotation and can contain
		# shear. Bake that full basis into the tiny hull, rather than asking
		# the physics transform decomposition to approximate it.
		var points := shapes[(i * 7919 + 3) % variants.size()].points
		for p in points.size():
			points[p] = xf.basis * points[p]
		var placed := ConvexPolygonShape3D.new()
		placed.points = points
		shape.shape = placed
		shape.position = xf.origin
		blocks[key].add_child(shape)


## Cache one small convex approximation per displayed mesh. Support points
## in fourteen directions follow the rock/stump better than an AABB box;
## convexity deliberately fills small cracks and root gaps. No trimesh/RNG.
static func _solid_shape(mesh: Mesh) -> ConvexPolygonShape3D:
	if _collision_cache.has(mesh):
		return _collision_cache[mesh]
	var directions := PackedVector3Array([Vector3.RIGHT, Vector3.LEFT, Vector3.UP,
		Vector3.DOWN, Vector3.FORWARD, Vector3.BACK])
	for x in [-1.0, 1.0]:
		for y in [-1.0, 1.0]:
			for z in [-1.0, 1.0]:
				directions.append(Vector3(x, y, z))
	var support := PackedVector3Array()
	var scores := PackedFloat32Array()
	support.resize(directions.size())
	scores.resize(directions.size())
	scores.fill(-INF)
	for surface in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for vertex in vertices:
			for d in directions.size():
				var score := vertex.dot(directions[d])
				if score > scores[d]:
					scores[d] = score
					support[d] = vertex
	var shape := ConvexPolygonShape3D.new()
	shape.points = support
	_collision_cache[mesh] = shape
	return shape


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
		mmi.set_meta("stream_reach", end)
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


## The same photographed clump as the grass carpet, on fixed stage spots.
## Only the pure mesh factory is shared: this material never follows a camera.
static func _tuft() -> ArrayMesh:
	var mesh := GrassField._card_tuft()
	var mat := ShaderMaterial.new()
	mat.shader = load("res://src/shaders/grass_cards_static.gdshader")
	mat.set_shader_parameter("grass_albedo", preload("res://assets/grass/grass_medium_01_diff_2k.jpg"))
	mat.set_shader_parameter("grass_alpha", preload("res://assets/grass/grass_medium_01_alpha_2k.png"))
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
