extends SceneTree
## Renders each tree from VIEWS directions into an impostor atlas: albedo with
## alpha, and view-space normals, so far trees are lit like near ones.
##   xvfb-run godot --path . --script res://tools/bake_impostors.gd
## Writes assets/trees/impostor_albedo.png and impostor_normal.png: one row per
## tree (a, b, c), one column per view, each CELL wide and 2 * CELL high.
## To review a candidate without replacing game assets, append:
##   -- --out-dir /path/to/candidate

const VIEWS := 8
const CELL := 256
const TREES := ["a", "b", "c"]
const SOURCE := "near"
const NORMAL_CONTRACT := "foliage-mapped-bake-view-v1; wood-legacy-approximate"

var vp: SubViewport
var cam: Camera3D
var holder: Node3D
var materials: Array[ShaderMaterial] = []
var bounds := {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var output_dir := "res://assets/trees"
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		if args.size() != 2 or args[0] != "--out-dir" or args[1].is_empty():
			push_error("Usage: --script res://tools/bake_impostors.gd [-- --out-dir PATH]")
			quit(1)
			return
		output_dir = args[1].replace("\\", "/")
	if DisplayServer.get_name() == "headless":
		push_error("Impostor baking requires a real display/renderer; --headless is not supported")
		quit(1)
		return
	print("Impostor normal contract: ", NORMAL_CONTRACT)
	_setup_viewport()
	var images: Array[Image] = [
		Image.create(CELL * VIEWS, CELL * 2 * TREES.size(), false, Image.FORMAT_RGBA8),
		Image.create(CELL * VIEWS, CELL * 2 * TREES.size(), false, Image.FORMAT_RGBA8),
	]
	var sizes: Array[float] = []
	for tree_i in TREES.size():
		if not _load_tree(tree_i):
			quit(1)
			return
		sizes.append(cam.size)
		for view_i in VIEWS:
			_place_camera(view_i)
			# Keep this mesh and camera unchanged for both members of the pair.
			var albedo: Image = await _capture(0)
			var normal: Image = await _capture(1)
			if albedo == null or normal == null:
				quit(1)
				return
			var label := "tree %s view %d" % [TREES[tree_i], view_i]
			if not _same_alpha(albedo, normal, label):
				quit(1)
				return
			var cell := Rect2i(0, 0, CELL, CELL * 2)
			var offset := Vector2i(view_i * CELL, tree_i * CELL * 2)
			images[0].blit_rect(albedo, cell, offset)
			images[1].blit_rect(normal, cell, offset)
			print("impostor pair verified: ", label)
	# Check the assembled result too. No output is written until every check passes.
	if not _same_alpha(images[0], images[1], "full atlas"):
		quit(1)
		return
	print("impostor bounds ", JSON.stringify(bounds))
	print("Verify Forest.IMPOSTOR_SIZE (a, b, c): ", sizes)
	var error := DirAccess.make_dir_recursive_absolute(output_dir)
	if error != OK:
		push_error("Cannot create impostor output directory: %s (%s)" % [output_dir, error_string(error)])
		quit(1)
		return
	for pass_i in 2:
		var filename := "impostor_albedo.png" if pass_i == 0 else "impostor_normal.png"
		var path := output_dir.path_join(filename)
		error = images[pass_i].save_png(path)
		if error != OK:
			push_error("Cannot save impostor atlas: %s (%s)" % [path, error_string(error)])
			quit(1)
			return
		print("Wrote ", path)
	quit(0)


func _setup_viewport() -> void:
	vp = SubViewport.new()
	vp.size = Vector2i(CELL, CELL * 2)
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	vp.own_world_3d = true
	# Bake at native cell resolution, without temporal history or partial alpha.
	vp.msaa_3d = Viewport.MSAA_DISABLED
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	vp.use_taa = false
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = 1.0
	root.add_child(vp)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_CLEAR_COLOR
	e.background_color = Color(0, 0, 0, 0)
	env.environment = e
	vp.add_child(env)
	cam = Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	# Camera interpolation also blends orthographic size between tree variants.
	cam.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	vp.add_child(cam)
	cam.make_current()
	holder = Node3D.new()
	holder.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	vp.add_child(holder)


func _load_tree(tree_i: int) -> bool:
	for c in holder.get_children():
		holder.remove_child(c)
		c.free()
	materials.clear()
	var mesh: ArrayMesh = load("res://assets/trees/fir_%s_%s.res" % [TREES[tree_i], SOURCE])
	if mesh == null:
		push_error("Cannot load impostor source tree %s" % TREES[tree_i])
		return false
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	for s in mesh.get_surface_count():
		var m := ShaderMaterial.new()
		m.shader = load("res://src/shaders/bake.gdshader")
		var src: Material = mesh.surface_get_material(s)
		if src is ShaderMaterial:
			# This adapter mirrors the existing foliage shader, not arbitrary materials.
			var label := "tree %s surface %d" % [TREES[tree_i], s]
			if src.shader == null or src.shader.resource_path != "res://src/shaders/foliage.gdshader":
				push_error("Unsupported shader for mapped foliage bake: " + label)
				mi.free()
				return false
			var normal_texture: Variant = src.get_shader_parameter("normal_tex")
			var alpha_cut: Variant = src.get_shader_parameter("alpha_cut")
			if not normal_texture is Texture2D or (alpha_cut != null and not is_equal_approx(float(alpha_cut), 0.42)):
				push_error("Foliage bake requires normal_tex and the existing 0.42 cutoff: " + label)
				mi.free()
				return false
			if not _has_foliage_tangents(mesh, s, label):
				mi.free()
				return false
			m.set_shader_parameter("normal_tex", normal_texture)
			m.set_shader_parameter("use_foliage_normal", true)
			print("Mapped foliage: ", label, ", normal_tex=", (normal_texture as Texture2D).resource_path, ", alpha_cut=0.42")
			m.set_shader_parameter("albedo_tex", src.get_shader_parameter("albedo_tex"))
			# Shader source_color defaults are sRGB, converted on upload. Keep
			# explicit Color/Vector3 values unchanged, but use Color for the
			# missing default so the unhinted bake uniform receives linear RGB.
			m.set_shader_parameter("tint", _foliage_tint(src))
			m.set_shader_parameter("cutout", true)
		elif src is StandardMaterial3D:
			m.set_shader_parameter("albedo_tex", (src as StandardMaterial3D).albedo_texture)
		else:
			push_error("Unsupported material on tree %s surface %d" % [TREES[tree_i], s])
			mi.free()
			return false
		mi.set_surface_override_material(s, m)
		materials.append(m)
	holder.add_child(mi)
	var aabb := mesh.get_aabb()
	var radius := maxf(maxf(absf(aabb.position.x), absf(aabb.end.x)), maxf(absf(aabb.position.z), absf(aabb.end.z)))
	var height := aabb.end.y
	cam.size = maxf(height, radius * 4.0) # orthographic size is the view height
	bounds[TREES[tree_i]] = {"radius": radius, "height": height, "camera_size": cam.size}
	return true


func _has_foliage_tangents(mesh: ArrayMesh, surface: int, label: String) -> bool:
	# Reuse the mesh's UV frame and handedness; never regenerate it during a bake.
	var arrays := mesh.surface_get_arrays(surface)
	if arrays[Mesh.ARRAY_VERTEX] == null or arrays[Mesh.ARRAY_NORMAL] == null or arrays[Mesh.ARRAY_TANGENT] == null or arrays[Mesh.ARRAY_TEX_UV] == null:
		push_error("Missing foliage UV tangent frame: " + label)
		return false
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var tangents: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	if vertices.is_empty() or normals.size() != vertices.size() or uvs.size() != vertices.size() or tangents.size() != vertices.size() * 4:
		push_error("Invalid foliage tangent-frame counts: " + label)
		return false
	for i in vertices.size():
		var t := Vector3(tangents[i * 4], tangents[i * 4 + 1], tangents[i * 4 + 2])
		var n := normals[i]
		var handedness := tangents[i * 4 + 3]
		if not n.is_finite() or not t.is_finite() or not uvs[i].is_finite() or not is_finite(handedness) or absf(n.length_squared() - 1.0) > 0.01 or absf(t.length_squared() - 1.0) > 0.01 or absf(t.dot(n)) > 0.01 or absf(absf(handedness) - 1.0) > 0.01:
			push_error("Invalid foliage tangent frame at vertex %d: %s" % [i, label])
			return false
	return true


func _place_camera(view_i: int) -> void:
	var a := TAU * view_i / VIEWS
	var h: float = cam.size
	var centre := Vector3(0, h * 0.5, 0)
	cam.look_at_from_position(centre + Vector3(sin(a), 0, cos(a)) * 40.0, centre)


func _capture(mode: int) -> Image:
	for material in materials:
		material.set_shader_parameter("mode", mode)
	# Warm up one rendered frame after configuration, then capture a second.
	# The draw fence, not a count of idle callbacks, guarantees completed output.
	for _frame in 2:
		await process_frame
		vp.render_target_update_mode = SubViewport.UPDATE_ONCE
		await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	if img == null or img.is_empty() or img.get_size() != Vector2i(CELL, CELL * 2):
		push_error("Impostor capture failed; a real renderer and a %dx%d viewport are required" % [CELL, CELL * 2])
		return null
	img.convert(Image.FORMAT_RGBA8)
	return img


func _same_alpha(albedo: Image, normal: Image, label: String) -> bool:
	if albedo.get_size() != normal.get_size():
		push_error("Impostor size mismatch: " + label)
		return false
	var a := albedo.get_data()
	var n := normal.get_data()
	var mismatches := 0
	var first_mismatch := -1
	var covered := 0
	var partial := 0
	for i in range(3, a.size(), 4):
		if a[i] != n[i]:
			mismatches += 1
			if first_mismatch < 0:
				first_mismatch = i >> 2
		if a[i] > 0:
			covered += 1
		if (a[i] != 0 and a[i] != 255) or (n[i] != 0 and n[i] != 255):
			partial += 1
	if mismatches > 0:
		push_error("Impostor alpha mismatch: %s, %d pixels, first pixel index %d; assets not written" % [label, mismatches, first_mismatch])
		return false
	if partial > 0:
		push_error("Partial alpha in impostor silhouette: %s, %d pixels; assets not written" % [label, partial])
		return false
	if covered == 0 or covered == albedo.get_width() * albedo.get_height():
		push_error("Empty or fully opaque impostor silhouette: %s; assets not written" % label)
		return false
	return true


## Preserve authored explicit values and their Variant colour semantics.
static func _foliage_tint(source: ShaderMaterial) -> Variant:
	var value: Variant = source.get_shader_parameter("tint")
	return Color(0.62, 0.66, 0.55) if value == null else value
