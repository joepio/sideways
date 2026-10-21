class_name GrassField
## Carpets of grass and berry shrubs around every camera. Each is one
## MultiMesh of small tufts on a fixed grid; the shader (grass_field.gdshader) moves the grid with the
## camera that draws it, in whole cells so nothing swims, jitters each tuft
## by a hash of its world cell, stands it on the ground from the stage's
## ground map and keeps it off the road. Each split-screen view gets its own
## carpet from the same mesh for free, and the CPU does nothing per frame.

## The carpets: [kind, cell, inner, radius, grow]. Dense small tufts close
## by, a coarser grid of bigger ones further out, and berry shrubs on the
## wood floor. "low" keeps one middling grass carpet.
const HIGH := [[0, 0.3, 0.0, 20.0, 1.0], [0, 0.7, 18.0, 60.0, 1.35], [1, 0.55, 0.0, 38.0, 1.0]]
const LOW := [[0, 0.5, 0.0, 40.0, 1.0]]
const GRASS := [Color(0.36, 0.46, 0.2), Color(0.62, 0.58, 0.36)]
const SHRUB := [Color(0.2, 0.32, 0.1), Color(0.52, 0.15, 0.07)] ## bilberry green, autumn red

static func build(parent: Node3D, ground: Image, origin: Vector2, detail := "high") -> void:
	var tex := ImageTexture.create_from_image(ground)
	RenderingServer.global_shader_parameter_set("ground_map", tex)
	RenderingServer.global_shader_parameter_set("ground_rect", Vector4(origin.x, origin.y, Stage.GRID, 0.0))
	var meshes := [_tuft(), _shrub()]
	for c in (LOW if detail == "low" else HIGH):
		var kind: int = c[0]
		var cell: float = c[1]
		var radius: float = c[3]
		var side := int(ceil(radius * 2.0 / cell))
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = meshes[kind]
		mm.instance_count = side * side
		var i := 0
		for z in side:
			for x in side:
				mm.set_instance_transform(i, Transform3D(Basis(), Vector3((x - side / 2) * cell, 0.0, (z - side / 2) * cell)))
				i += 1
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "GrassField" if kind == 0 else "Shrubs"
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# The grid is moved in the shader: never cull it.
		mmi.custom_aabb = AABB(Vector3(-1e5, -1e4, -1e5), Vector3(2e5, 2e4, 2e5))
		var mat := ShaderMaterial.new()
		mat.shader = preload("res://src/shaders/grass_field.gdshader")
		mat.set_shader_parameter("kind", kind)
		mat.set_shader_parameter("cell", cell)
		mat.set_shader_parameter("inner", c[2])
		mat.set_shader_parameter("radius", radius)
		mat.set_shader_parameter("grow", c[4])
		mat.set_shader_parameter("span", side * cell)
		var colors: Array = GRASS if kind == 0 else SHRUB
		mat.set_shader_parameter("green", colors[0])
		mat.set_shader_parameter("dry", colors[1])
		mmi.material_override = mat
		parent.add_child(mmi)


## A low berry shrub: a few twigs, each with small oval leaves held flat-ish
## to the light. UV.y is height 0..1.
static func _shrub() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var top := 0.45
	for twig in 4:
		var a := TAU * twig / 4.0 + rng.randf_range(-0.5, 0.5)
		var out := Vector3(cos(a), 0.0, sin(a))
		var h := rng.randf_range(0.22, top)
		for leaf in 6:
			var t := (leaf + 1) / 6.0
			var c := out * rng.randf_range(0.08, 0.22) * t * 1.6 + Vector3.UP * h * t
			# Each leaf faces up and out at a random tilt.
			var n := Vector3(rng.randf_range(-1.0, 1.0), rng.randf_range(0.5, 1.2), rng.randf_range(-1.0, 1.0)).normalized()
			var along := n.cross(Vector3(n.z, 0.0, -n.x).normalized() if absf(n.y) < 0.99 else Vector3.RIGHT).normalized()
			var across := n.cross(along).normalized()
			var len_ := rng.randf_range(0.055, 0.085)
			var wid := len_ * 0.6
			var shade_n := (n + Vector3.UP * 0.5).normalized()
			var v := c.y / top
			var q := [c - along * len_, c - across * wid, c + across * wid, c + along * len_]
			for k in [0, 1, 2, 2, 1, 3]:
				st.set_uv(Vector2(0.5, v))
				st.set_normal(shade_n)
				st.add_vertex(q[k])
	st.index()
	return st.commit()


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
	st.index()
	return st.commit()
