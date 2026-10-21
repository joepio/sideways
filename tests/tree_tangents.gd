extends SceneTree
## Offline tangent generator regression. --assets also checks repaired trees.

const BAKER := preload("res://tools/bake_trees.gd")


func _initialize() -> void:
	for mirror in [false, true]:
		var arrays := _quad(mirror)
		var before := arrays.duplicate(true)
		if not BAKER.add_uv_tangents(arrays, "mirrored quad" if mirror else "rotated quad"):
			quit(1)
			return
		for channel in Mesh.ARRAY_MAX:
			if channel != Mesh.ARRAY_TANGENT and not _check(arrays[channel] == before[channel], "Generator changed a non-tangent array"):
				return
		var tangents: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
		if not _check(tangents.size() == 16, "Quad needs one tangent per vertex"):
			return
		for i in 4:
			var t := Vector3(tangents[i * 4], tangents[i * 4 + 1], tangents[i * 4 + 2])
			var expected := Vector3.BACK if mirror else Vector3.FORWARD
			if not _check(t.dot(expected) > 0.999, "Tangent does not follow rotated/mirrored UV direction"):
				return
			# Godot's MikkTSpace adapter reverses the generated bitangent.
			if not _check(is_equal_approx(tangents[i * 4 + 3], -1.0 if mirror else 1.0), "Mirroring did not change tangent handedness"):
				return
	var degenerate := _quad(false)
	degenerate[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
	var before_degenerate := degenerate.duplicate(true)
	if not _check(BAKER.add_uv_tangents(degenerate, "degenerate UV quad"), "Degenerate UV fallback failed"):
		return
	if not _check(degenerate == before_degenerate, "Degenerate UV surface changed"):
		return
	if "--assets" in OS.get_cmdline_user_args() and not _check_assets():
		return
	print("tree tangents: rotated/mirrored UVs, handedness, unchanged arrays and degenerate fallback passed")
	quit()


func _quad(mirror: bool) -> Array:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.FORWARD, Vector3.RIGHT + Vector3.FORWARD])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP])
	var u := -1.0 if mirror else 1.0
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2.ZERO, Vector2(0, 1), Vector2(u, 0), Vector2(u, 1)])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 1, 3, 2])
	return arrays


func _check_assets() -> bool:
	for variant in ["a", "b", "c"]:
		for detail in ["near", "mid"]:
			var path := "res://assets/trees/fir_%s_%s.res" % [variant, detail]
			var mesh := load(path) as ArrayMesh
			if not _check(mesh != null, "Missing tree mesh: %s" % path):
				return false
			var found := false
			for surface in mesh.get_surface_count():
				if mesh.surface_get_name(surface) != "twig":
					continue
				found = true
				var arrays := mesh.surface_get_arrays(surface)
				var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
				var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
				var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
				var tangents: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
				if not _check(tangents.size() == vertices.size() * 4, "Missing needle tangents: %s" % path):
					return false
				var alignment := 0.0
				var samples := 0
				for triangle in range(0, indices.size(), 3):
					var a := indices[triangle]
					var b := indices[triangle + 1]
					var c := indices[triangle + 2]
					var u := uv[b] - uv[a]
					var v := uv[c] - uv[a]
					var det := u.cross(v)
					if absf(det) < 1e-10:
						continue
					var expected := ((vertices[b] - vertices[a]) * v.y - (vertices[c] - vertices[a]) * u.y) / det
					expected = (expected - normals[a] * expected.dot(normals[a])).normalized()
					if expected.length_squared() < 0.5:
						continue
					var actual := Vector3(tangents[a * 4], tangents[a * 4 + 1], tangents[a * 4 + 2])
					alignment += actual.dot(expected)
					samples += 1
				if not _check(samples > 0 and alignment / maxf(samples, 1) > 0.95, "Needle tangents do not follow UVs: %s" % path):
					return false
			if not _check(found, "Missing needle surface: %s" % path):
				return false
	print("tree tangents: six repaired needle surfaces follow their UVs")
	return true


func _check(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
		quit(1)
	return condition
