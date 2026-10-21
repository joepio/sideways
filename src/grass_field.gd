class_name GrassField
## A carpet of grass around every camera. One MultiMesh of small tufts on a
## fixed grid; the shader (grass_field.gdshader) moves the grid with the
## camera that draws it, in whole cells so nothing swims, jitters each tuft
## by a hash of its world cell, stands it on the ground from the stage's
## ground map and keeps it off the road. Each split-screen view gets its own
## carpet from the same mesh for free, and the CPU does nothing per frame.

const CELL := 0.5 ## metres between tufts
const RADIUS := 40.0

static func build(parent: Node3D, ground: Image, origin: Vector2) -> void:
	var tex := ImageTexture.create_from_image(ground)
	RenderingServer.global_shader_parameter_set("ground_map", tex)
	RenderingServer.global_shader_parameter_set("ground_rect", Vector4(origin.x, origin.y, Stage.GRID, 0.0))
	var side := int(RADIUS * 2.0 / CELL)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _tuft()
	mm.instance_count = side * side
	var i := 0
	for z in side:
		for x in side:
			mm.set_instance_transform(i, Transform3D(Basis(), Vector3((x - side / 2) * CELL, 0.0, (z - side / 2) * CELL)))
			i += 1
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "GrassField"
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The grid is moved in the shader: never cull it.
	mmi.custom_aabb = AABB(Vector3(-1e5, -1e4, -1e5), Vector3(2e5, 2e4, 2e5))
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://src/shaders/grass_field.gdshader")
	mat.set_shader_parameter("cell", CELL)
	mat.set_shader_parameter("radius", RADIUS)
	mat.set_shader_parameter("span", side * CELL)
	mmi.material_override = mat
	parent.add_child(mmi)


## Five thin blades from one root, three segments each; UV.y is height 0..1.
static func _tuft() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for b in 5:
		var a := TAU * b / 5.0 + rng.randf_range(-0.4, 0.4)
		var lean := Vector3(cos(a), 0.0, sin(a)) * rng.randf_range(0.06, 0.16)
		var base := Vector3(cos(a), 0.0, sin(a)) * rng.randf_range(0.0, 0.06)
		var h := rng.randf_range(0.28, 0.5)
		var w := rng.randf_range(0.018, 0.028)
		var side := Vector3(-sin(a), 0.0, cos(a))
		var rows: Array[PackedVector3Array] = []
		for k in 4:
			var t := k / 3.0
			var c := base + Vector3(0.0, h * t, 0.0) + lean * t * t
			var hw := w * (1.0 - t * 0.85)
			rows.append(PackedVector3Array([c - side * hw, c + side * hw]))
		for k in 3:
			var t0 := k / 3.0
			var t1 := (k + 1) / 3.0
			var q := [rows[k][0], rows[k][1], rows[k + 1][0], rows[k + 1][1]]
			var uv := [Vector2(0, t0), Vector2(1, t0), Vector2(0, t1), Vector2(1, t1)]
			for idx in [0, 2, 1, 1, 2, 3]:
				st.set_uv(uv[idx])
				st.set_normal(Vector3.UP)
				st.add_vertex(q[idx])
	return st.commit()
