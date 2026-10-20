extends SceneTree
## Renders the tree meshes side by side: tools/shot-style, under xvfb.
##   xvfb-run godot --path . --resolution 1280x720 --script res://tools/preview_trees.gd -- out.png

var frames := 0
var out := ""


func _initialize() -> void:
	out = OS.get_cmdline_user_args()[0]
	var root3 := Node3D.new()
	root.add_child(root3)
	var env := WorldEnvironment.new()
	env.environment = Look.environment()
	root3.add_child(env)
	root3.add_child(Look.sun())
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(200, 200)
	var gm := StandardMaterial3D.new()
	gm.albedo_texture = load("res://assets/textures/forest_leaves_04_albedo.jpg")
	gm.uv1_scale = Vector3(60, 60, 1)
	pm.material = gm
	ground.mesh = pm
	root3.add_child(ground)
	var x := -15.0
	for t in ["a", "b", "c"]:
		for lod in ["near", "mid"]:
			var mi := MeshInstance3D.new()
			mi.mesh = load("res://assets/trees/fir_%s_%s.res" % [t, lod])
			mi.position = Vector3(x, 0, 0)
			root3.add_child(mi)
			x += 6.0
	var cam := Camera3D.new()
	cam.fov = 60
	root3.add_child(cam)
	cam.look_at_from_position(Vector3(0, 7, 26), Vector3(0, 8, 0))


func _process(_d: float) -> bool:
	frames += 1
	if frames == 4:
		root.get_texture().get_image().save_png(out)
		return true
	return false
