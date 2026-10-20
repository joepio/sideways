extends SceneTree
## Renders each tree from VIEWS directions into an impostor atlas: albedo with
## alpha, and view-space normals, so far trees are lit like near ones.
##   xvfb-run godot --path . --script res://tools/bake_impostors.gd
## Writes assets/trees/impostor_albedo.png and impostor_normal.png: one row per
## tree (a, b, c), one column per view, each CELL wide and 2 * CELL high.

const VIEWS := 8
const CELL := 256
const TREES := ["a", "b", "c"]
const SOURCE := "near"

var vp: SubViewport
var cam: Camera3D
var holder: Node3D
var step := 0
var tree_i := 0
var view_i := 0
var pass_i := 0
var images := [Image.create(CELL * VIEWS, CELL * 2 * TREES.size(), false, Image.FORMAT_RGBA8),
	Image.create(CELL * VIEWS, CELL * 2 * TREES.size(), false, Image.FORMAT_RGBA8)]
var bounds := {}


func _initialize() -> void:
	vp = SubViewport.new()
	vp.size = Vector2i(CELL, CELL * 2)
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.own_world_3d = true
	root.add_child(vp)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_CLEAR_COLOR
	e.background_color = Color(0, 0, 0, 0)
	env.environment = e
	vp.add_child(env)
	cam = Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	vp.add_child(cam)
	holder = Node3D.new()
	vp.add_child(holder)
	_load_tree()


func _load_tree() -> void:
	for c in holder.get_children():
		c.queue_free()
	var mesh: ArrayMesh = load("res://assets/trees/fir_%s_%s.res" % [TREES[tree_i], SOURCE])
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	for s in mesh.get_surface_count():
		var m := ShaderMaterial.new()
		m.shader = load("res://src/shaders/bake.gdshader")
		var src: Material = mesh.surface_get_material(s)
		if src is ShaderMaterial:
			m.set_shader_parameter("albedo_tex", src.get_shader_parameter("albedo_tex"))
			m.set_shader_parameter("tint", src.get_shader_parameter("tint") if src.get_shader_parameter("tint") != null else Vector3(0.62, 0.66, 0.55))
			m.set_shader_parameter("cutout", true)
		else:
			m.set_shader_parameter("albedo_tex", (src as StandardMaterial3D).albedo_texture)
		m.set_shader_parameter("mode", pass_i)
		mi.set_surface_override_material(s, m)
	holder.add_child(mi)
	var aabb := mesh.get_aabb()
	var radius := maxf(maxf(absf(aabb.position.x), absf(aabb.end.x)), maxf(absf(aabb.position.z), absf(aabb.end.z)))
	var height := aabb.end.y
	bounds[TREES[tree_i]] = {"radius": radius, "height": height}
	cam.size = maxf(height, radius * 4.0) # orthographic size is the view height
	_place_camera()


func _place_camera() -> void:
	var a := TAU * view_i / VIEWS
	var h: float = cam.size
	var centre := Vector3(0, h * 0.5, 0)
	cam.look_at_from_position(centre + Vector3(sin(a), 0, cos(a)) * 40.0, centre)


func _process(_d: float) -> bool:
	step += 1
	if step % 3 != 0:
		return false
	var img := vp.get_texture().get_image()
	img.convert(Image.FORMAT_RGBA8)
	img.resize(CELL, CELL * 2)
	images[pass_i].blit_rect(img, Rect2i(0, 0, CELL, CELL * 2), Vector2i(view_i * CELL, tree_i * CELL * 2))
	view_i += 1
	if view_i < VIEWS:
		_place_camera()
		return false
	view_i = 0
	tree_i += 1
	if tree_i >= TREES.size():
		tree_i = 0
		pass_i += 1
		if pass_i > 1:
			images[0].save_png("res://assets/trees/impostor_albedo.png")
			images[1].save_png("res://assets/trees/impostor_normal.png")
			print("impostor bounds ", bounds)
			return true
	_load_tree()
	return false
