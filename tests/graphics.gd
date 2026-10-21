extends SceneTree
## Regression: translating props must retain both index widths and every LOD.


func _initialize() -> void:
	for count in [3, 65537]:
		var vertices := PackedVector3Array()
		vertices.resize(count)
		vertices[count - 2] = Vector3.RIGHT
		vertices[count - 1] = Vector3.UP
		var indices := PackedInt32Array([0, count - 2, count - 1])
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_INDEX] = indices + indices
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {1.0: indices})
		var lods := GroundCover._lods(mesh, 0)
		assert(lods.size() == 1)
		assert(lods[1.0] == indices, "Packed LOD indices changed")
	var path := "res://assets/props/tree_stump_01/tree_stump_01.gltf"
	var original: Node = load(path).instantiate()
	var src: Mesh = original.find_children("*", "MeshInstance3D")[0].mesh
	var translated: Mesh = GroundCover._meshes(path)[0]
	assert(src.get_surface_count() == translated.get_surface_count())
	for surface in src.get_surface_count():
		var before := GroundCover._lods(src, surface)
		var after := GroundCover._lods(translated, surface)
		assert(not before.is_empty(), "Fixture needs imported LODs")
		assert(before == after, "Prop translation lost LODs")
		assert(src.surface_get_arrays(surface)[Mesh.ARRAY_INDEX] == translated.surface_get_arrays(surface)[Mesh.ARRAY_INDEX])
		assert(src.surface_get_material(surface) == translated.surface_get_material(surface))
	original.free()
	var near := GrassField._tuft()
	var far := GrassField._tuft(1)
	assert(near.get_aabb().is_equal_approx(far.get_aabb()), "Grass silhouette bounds changed")
	assert(far.surface_get_array_index_len(0) * 3 == near.surface_get_array_index_len(0))
	print("graphics: LOD indices (16/32 bit), prop materials and grass bounds passed")
	quit()
