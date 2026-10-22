extends SceneTree
## Real Forest output versus the pinned pre-candidate builder. This verifies
## instance/bounds/material contracts; real shadow fading still needs GPU motion QA.
const ReferenceForest := preload("res://tests/fixtures/forest_shadow_reference.gd")
var failures: Array[String] = []
var checks := 0
var _headless := false

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	_headless = DisplayServer.get_name() == "headless"
	var spots: Array[Transform3D] = []
	for i in 24:
		var x := float((i % 6) * 17 - 41)
		var z := float((i / 6) * 19 - 32)
		var scale_ := Vector3(0.8 + float(i % 4) * 0.1, 0.85 + float(i % 3) * 0.14, 0.8 + float(i % 4) * 0.1)
		spots.append(Transform3D(Basis(Vector3.UP, float(i) * 0.37).scaled(scale_), Vector3(x, float(i % 5) * 0.3, z)))
	for views in [1, 2, 4]:
		var before := Node3D.new()
		var after := Node3D.new()
		# Static transformed parents exercise world-centre registration rather
		# than accidentally passing because the stage is at the world origin.
		var parent_transform := Transform3D(Basis(Vector3.UP, 0.43).scaled(Vector3(1.1, 0.95, 1.1)), Vector3(-73.0, 4.0, 128.0))
		before.transform = parent_transform
		after.transform = parent_transform
		root.add_child(before)
		root.add_child(after)
		ReferenceForest.build(before, spots, views)
		Forest.build(after, spots, views)
		_check(before.get_child_count() == after.get_child_count(), "changed draw-instance count")
		var shared_meshes := {}
		var block_values := {}
		for i in mini(before.get_child_count(), after.get_child_count()):
			var old := before.get_child(i) as MultiMeshInstance3D
			var current := after.get_child(i) as MultiMeshInstance3D
			_check(old != null and current != null, "unexpected Forest node type")
			if old == null or current == null:
				continue
			_check(old.cast_shadow == current.cast_shadow, "changed caster class")
			_check(old.visibility_range_begin == current.visibility_range_begin and old.visibility_range_end == current.visibility_range_end, "changed cull range")
			_check(old.visibility_range_begin_margin == current.visibility_range_begin_margin and old.visibility_range_end_margin == current.visibility_range_end_margin and old.visibility_range_fade_mode == current.visibility_range_fade_mode, "changed native cull margins/fade")
			_check(old.get_meta("stream_reach", -1.0) == current.get_meta("stream_reach", -1.0), "changed streamer budget")
			if not _headless:
				_check(current.get_aabb().size.length() > 1.0, "renderer did not resolve an actual MultiMesh AABB")
				_check(old.get_aabb() == current.get_aabb(), "changed actual block AABB")
			_check(old.global_transform == current.global_transform, "changed block transform")
			_check(old.multimesh.instance_count == current.multimesh.instance_count, "changed tree count")
			for tree in old.multimesh.instance_count:
				_check(old.multimesh.get_instance_transform(tree) == current.multimesh.get_instance_transform(tree), "changed tree placement")
			var old_mesh := old.multimesh.mesh
			var new_mesh := current.multimesh.mesh
			_check(old_mesh.get_surface_count() == new_mesh.get_surface_count(), "changed surface count")
			var shadows_only := current.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
			_check(current.multimesh.use_custom_data == shadows_only, "custom buffer must be shadow-only")
			_check(not current.multimesh.use_colors, "unexpected instance colour buffer")
			for property in current.get_property_list():
				_check(not String(property.name).begins_with("instance_shader_parameters/"), "caster consumes renderer-global instance uniforms")
			for surface in old_mesh.get_surface_count():
				_check(var_to_bytes(old_mesh.surface_get_arrays(surface)) == var_to_bytes(new_mesh.surface_get_arrays(surface)), "changed decoded source geometry")
				var old_material := old_mesh.surface_get_material(surface) as ShaderMaterial
				var new_material := new_mesh.surface_get_material(surface) as ShaderMaterial
				_check(old_material != null and new_material != null, "missing shader material")
				if old_material == null or new_material == null:
					continue
				if shadows_only:
					_check(new_material.shader == Forest.SHADOW, "caster lacks dedicated shadow shader")
					var is_foliage := old_material.shader == Forest.FOLIAGE
					_check(bool(new_material.get_shader_parameter("foliage")) == is_foliage, "wood/crown vertex contract changed")
					if is_foliage:
						_check(old_material.get_shader_parameter("albedo_tex") == new_material.get_shader_parameter("albedo_tex"), "authored shadow alpha texture changed")
						for parameter in ["alpha_cut", "sway"]:
							var expected := _effective_float(old_material, parameter)
							var actual: Variant = new_material.get_shader_parameter(parameter)
							_check(actual != null and is_equal_approx(float(actual), expected), "authored shadow alpha/wind changed: %s expected=%s explicit=%s" % [parameter, expected, actual])
					_check(float(new_material.get_shader_parameter("shadow_fade_width")) == 12.0, "unexpected fade width")
				else:
					_check(old_material.shader == new_material.shader, "visible tree shader changed")
					for parameter in ["fade_in_at", "fade_out_at", "fade_in_width", "fade_out_width", "albedo_tex", "normal_tex", "albedo_atlas", "normal_atlas", "tint", "sway", "alpha_cut"]:
						_check(old_material.get_shader_parameter(parameter) == new_material.get_shader_parameter(parameter), "visible explicit material binding changed: " + parameter)
					for uniform in old_material.shader.get_shader_uniform_list():
						var parameter: StringName = uniform.name
						_check(old_material.get_shader_parameter(parameter) == new_material.get_shader_parameter(parameter), "visible material/LOD parameter changed: " + String(parameter))
			if shadows_only:
				# These actual custom values are also supplied as INSTANCE_CUSTOM.
				# Color is raw float32 data here, not an sRGB material uniform.
				var transformed: AABB = current.global_transform * current.get_aabb()
				var centre := transformed.get_center()
				# Dummy rendering ignores instance setters and returns Color(); only
				# a real renderer can verify either centre or end in this buffer.
				if not _headless:
					for tree in current.multimesh.instance_count:
						var binding := current.multimesh.get_instance_custom_data(tree)
						_check(Vector3(binding.r, binding.g, binding.b).is_equal_approx(centre), "custom fade centre differs from renderer AABB centre")
						_check(is_equal_approx(binding.a, old.visibility_range_end), "custom fade extends beyond old caster range")
						block_values[binding] = true
					var buffer := current.multimesh.buffer
					_check(buffer.size() == current.multimesh.instance_count * 16, "shadow buffer must contain twelve transform and four custom floats per tree")
					if buffer.size() == current.multimesh.instance_count * 16:
						for tree in current.multimesh.instance_count:
							var offset := tree * 16 + 12
							_check(Vector3(buffer[offset], buffer[offset + 1], buffer[offset + 2]).is_equal_approx(centre) and is_equal_approx(buffer[offset + 3], old.visibility_range_end), "actual GPU buffer custom data differs")
				if shared_meshes.has(old_mesh):
					_check(shared_meshes[old_mesh] == new_mesh, "per-block mesh/material duplication")
				else:
					shared_meshes[old_mesh] = new_mesh
		_check(shared_meshes.size() == 3, "fixture must exercise all shared variants")
		if not _headless:
			_check(block_values.size() > 3, "fixture must exercise distinct actual block bindings")
		before.free()
		after.free()
	if failures.is_empty():
		print("forest shadow fade: %d actual-node/material/geometry checks passed; renderer AABB checked=%s; GPU fade quality not tested" % [checks, not _headless])
	else:
		for message in failures:
			push_error(message)
	quit(0 if failures.is_empty() else 1)

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)


func _effective_float(material: ShaderMaterial, parameter: String) -> float:
	var value: Variant = material.get_shader_parameter(parameter)
	if value == null:
		value = RenderingServer.shader_get_parameter_default(material.shader.get_rid(), parameter)
	if value == null:
		_check(_headless, "Real renderer failed to resolve source shader default: " + parameter)
		value = 0.42 if parameter == "alpha_cut" else 0.04
	return float(value)
