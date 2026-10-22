extends SceneTree
## Actual Forest per-view meshes/materials. GPU shadow appearance is a separate gate.
var checks := 0
var failures: Array[String] = []
var _headless := false

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	_headless = DisplayServer.get_name() == "headless"
	var spots: Array[Transform3D] = []
	for i in 24:
		spots.append(Transform3D(Basis(Vector3.UP, float(i) * 0.37).scaled(Vector3.ONE * (0.8 + float(i % 4) * 0.1)), Vector3(float(i % 6) * 3.0 - 8.0, float(i % 3), -float(i / 6) * 6.0 - 8.0)))
	for count in [1, 2, 4]:
		var world := Node3D.new()
		root.add_child(world)
		var sets := Forest.build(world, spots, count)
		sets.set_process(false)
		var cameras: Array = []
		for index in count:
			var camera := Camera3D.new()
			camera.cull_mask = TreeSets.cull_mask(index)
			camera.position = Vector3(0.0, 4.0, 0.0)
			world.add_child(camera)
			cameras.append(camera)
		sets.eyes = func() -> Array: return cameras
		sets._process(0.0)
		_check(sets._views.size() == count, "missing actual per-view sets")
		_check(sets.get_child_count() == count * 9, "changed nine-draw view budget")
		var expected_end := 26.75 if count >= 3 else 33.0
		for variant in Forest.VARIANTS.size():
			var source: Mesh = load("res://assets/trees/fir_%s_mid.res" % Forest.VARIANTS[variant])
			var shade: Mesh = sets.meshes[variant][1]
			_check(source.get_surface_count() == shade.get_surface_count(), "shadow surface count changed")
			for surface in source.get_surface_count():
				_check(var_to_bytes(source.surface_get_arrays(surface)) == var_to_bytes(shade.surface_get_arrays(surface)), "shadow source geometry changed")
				var original := source.surface_get_material(surface)
				var material := shade.surface_get_material(surface) as ShaderMaterial
				_check(material != null and material.shader == Forest.SHADOW, "dedicated shared shadow material missing")
				if material == null: continue
				_check(is_equal_approx(float(material.get_shader_parameter("shadow_fade_end")), expected_end), "shadow fade exceeds selected per-tree range")
				_check(float(material.get_shader_parameter("shadow_fade_width")) == 12.0, "shadow fade width changed")
				_check(bool(material.get_shader_parameter("foliage")) == (original is ShaderMaterial), "wood/crown alpha contract changed")
				if original is ShaderMaterial:
					_check(original.shader == Forest.FOLIAGE, "unexpected authored crown shader")
					_check(material.get_shader_parameter("albedo_tex") == original.get_shader_parameter("albedo_tex"), "authored alpha changed")
					for parameter in ["alpha_cut", "sway"]:
						var expected := _effective_float(original, parameter)
						var actual: Variant = material.get_shader_parameter(parameter)
						_check(actual != null and is_equal_approx(float(actual), expected), "explicit alpha/wind mismatch: " + parameter)
				if not _headless:
					_check(not material.shader.get_shader_uniform_list().is_empty(), "real renderer did not compile shadow uniforms")
		for index in count:
			var view: Dictionary = sets._views[index]
			for variant in Forest.VARIANTS.size():
				for level in 3:
					var node: MultiMeshInstance3D = view.sets[variant][level]
					_check(node.multimesh.mesh == sets.meshes[variant][level], "per-view mesh/material duplication")
					_check(node.layers == 1 << (TreeSets.LAYER0 + index), "wrong view layer")
					_check(node.cast_shadow == (GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY if level == 1 else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF), "wrong caster class")
					_check(not node.multimesh.use_custom_data and not node.multimesh.use_colors, "unexpected per-tree payload")
					_check(node.visibility_range_begin == 0.0 and node.visibility_range_end == 0.0, "obsolete block-distance culling retained")
					for property in node.get_property_list():
						_check(not String(property.name).begins_with("instance_shader_parameters/"), "renderer-global instance uniform allocated")
					var buffer := node.multimesh.buffer
					_check(buffer.size() == node.multimesh.instance_count * 12, "tree buffer is not transform-only")
		sets.eyes = Callable()
		world.free()
	if failures.is_empty():
		print("forest shadow fade: %d per-view geometry/material checks passed; real_renderer=%s; visual fade not tested" % [checks, not _headless])
	else:
		for message in failures: push_error(message)
	quit(0 if failures.is_empty() else 1)

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _effective_float(material: ShaderMaterial, parameter: String) -> float:
	var value: Variant = material.get_shader_parameter(parameter)
	if value == null:
		value = RenderingServer.shader_get_parameter_default(material.shader.get_rid(), parameter)
	if value == null:
		_check(_headless, "Real renderer failed to resolve source shader default: " + parameter)
		value = 0.42 if parameter == "alpha_cut" else 0.04
	return float(value)
