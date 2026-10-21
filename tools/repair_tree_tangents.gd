extends SceneTree
## Offline, tangent-only repair of the six baked tree meshes. Try in a staging
## checkout first; this writes assets/trees/fir_*_{near,mid}.res in this project.
##   godot --headless --path . --script res://tools/repair_tree_tangents.gd
##   godot --headless --path . --script res://tests/tree_tangents.gd -- --assets
## Only needle-card surfaces change. Authored/procedural bark is left alone.

const BAKER := preload("res://tools/bake_trees.gd")
const VARIANTS := ["a", "b", "c"]
const DETAILS := ["near", "mid"]


func _initialize() -> void:
	var pending: Array[Dictionary] = []
	# Prepare and validate every mesh before writing any of them.
	for variant in VARIANTS:
		for detail in DETAILS:
			var path := "res://assets/trees/fir_%s_%s.res" % [variant, detail]
			var original := load(path) as ArrayMesh
			if original == null:
				_fail("Cannot load tree mesh: %s" % path)
				return
			var repaired := _repair(original, path)
			if repaired == null:
				quit(1)
				return
			pending.append({"path": path, "mesh": repaired})
	for item in pending:
		var path: String = item.path
		var mesh: ArrayMesh = item.mesh
		var error := ResourceSaver.save(mesh, path, ResourceSaver.FLAG_COMPRESS)
		if error != OK:
			_fail("Cannot save repaired tree %s: %s" % [path, error_string(error)])
			return
		print("repaired twig tangents: ", path)
	print("tree tangents: repaired six meshes; positions, indices, LODs and materials retained")
	quit()


func _repair(original: ArrayMesh, path: String) -> ArrayMesh:
	var repaired := ArrayMesh.new()
	repaired.resource_name = original.resource_name
	repaired.custom_aabb = original.custom_aabb
	repaired.lightmap_size_hint = original.lightmap_size_hint
	repaired.blend_shape_mode = original.blend_shape_mode
	repaired.shadow_mesh = original.shadow_mesh
	for shape in original.get_blend_shape_count():
		repaired.add_blend_shape(original.get_blend_shape_name(shape))
	for key in original.get_meta_list():
		repaired.set_meta(key, original.get_meta(key))
	# Repacking decoded arrays changes even untouched octahedral normals by
	# quantization. Retain each original serialized surface and patch only its
	# tangent bytes. This also retains every LOD and optional attribute channel.
	var source_surfaces: Array = original.get("_surfaces")
	var surfaces := source_surfaces.duplicate(true)
	var twig_count := 0
	for surface in original.get_surface_count():
		var name := original.surface_get_name(surface)
		if name == "twig":
			if original.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
				push_error("Needle surface is not triangles: %s" % path)
				return null
			var arrays := original.surface_get_arrays(surface)
			if not BAKER.add_uv_tangents(arrays, "%s/%s" % [path, name]):
				return null
			if not _patch_tangent_bytes(surfaces[surface], arrays, "%s/%s" % [path, name]):
				return null
			twig_count += 1
	if twig_count != 1:
		push_error("Expected exactly one needle surface: %s" % path)
		return null
	repaired.set("_surfaces", surfaces)
	if repaired.get_surface_count() != original.get_surface_count() or repaired.get("_surfaces") != surfaces:
		push_error("Tree reconstruction changed packed surface data: %s" % path)
		return null
	for surface in original.get_surface_count():
		var name := original.surface_get_name(surface)
		var result := repaired.surface_get_arrays(surface)
		var before := original.surface_get_arrays(surface)
		for channel in Mesh.ARRAY_MAX:
			if name == "twig" and channel == Mesh.ARRAY_TANGENT:
				continue
			if result[channel] != before[channel]:
				push_error("Tree reconstruction changed array %d: %s/%s" % [channel, path, name])
				return null
		# In particular, LOD bytes, blend shapes, surface names/materials and
		# every attribute/skin buffer must be identical to the original.
		var before_data: Dictionary = source_surfaces[surface]
		var after_data: Dictionary = surfaces[surface]
		for key in before_data:
			if name == "twig" and key == "vertex_data":
				continue
			if before_data[key] != after_data.get(key):
				push_error("Tree repair changed packed field %s: %s/%s" % [key, path, name])
				return null
	return repaired


## Existing trees use separate octahedral normals and tangents, four bytes
## each. Reject joint compression rather than modify normals/positions too.
## Let Godot pack the generated tangents; copy just their bytes into the old
## buffer using the engine's format offsets, without assuming an interleave.
func _patch_tangent_bytes(data: Dictionary, arrays: Array, label: String) -> bool:
	var format: int = data.format
	var count: int = data.vertex_count
	if (format & Mesh.ARRAY_FLAG_COMPRESS_ATTRIBUTES) != 0 or (format & Mesh.ARRAY_FORMAT_TANGENT) == 0:
		push_error("Tree repair requires separate existing tangent data: %s" % label)
		return false
	var temporary := ArrayMesh.new()
	temporary.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, format)
	if temporary.get_surface_count() != 1:
		push_error("Could not pack generated tangents: %s" % label)
		return false
	var generated := RenderingServer.mesh_get_surface(temporary.get_rid(), 0)
	var generated_format: int = generated.format
	if int(generated.vertex_count) != count or (generated_format & Mesh.ARRAY_FLAG_COMPRESS_ATTRIBUTES) != 0:
		push_error("Generated tangent packing changed vertex layout: %s" % label)
		return false
	var offset := RenderingServer.mesh_surface_get_format_offset(format, count, Mesh.ARRAY_TANGENT)
	var stride := RenderingServer.mesh_surface_get_format_normal_tangent_stride(format, count)
	var generated_offset := RenderingServer.mesh_surface_get_format_offset(generated_format, count, Mesh.ARRAY_TANGENT)
	var generated_stride := RenderingServer.mesh_surface_get_format_normal_tangent_stride(generated_format, count)
	var packed: PackedByteArray = data.vertex_data.duplicate()
	var tangent_source: PackedByteArray = generated.vertex_data
	if count <= 0 or stride < 4 or generated_stride < 4 or offset + (count - 1) * stride + 4 > packed.size() or generated_offset + (count - 1) * generated_stride + 4 > tangent_source.size():
		push_error("Invalid packed tangent range: %s" % label)
		return false
	for vertex in count:
		for byte in 4:
			packed[offset + vertex * stride + byte] = tangent_source[generated_offset + vertex * generated_stride + byte]
	data.vertex_data = packed
	return true


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
