class_name GrassField
## Carpets of grass and berry shrubs around every camera. Each is one
## MultiMesh of small tufts on a fixed grid; the shader (grass_field.gdshader) moves the grid with the
## camera that draws it, in whole cells so nothing swims, jitters each tuft
## by a hash of its world cell, stands it on the ground from the stage's
## ground map and keeps it off the road. Each split-screen view gets its own
## carpet from the same mesh for free, and the CPU does nothing per frame.

## The carpets: [kind, cell, inner, radius, grow]. Dense small tufts close
## by, coarser grids of bigger ones further out (a far ring so the edge
## isn't seen), and berry shrubs on the
## wood floor. Each split-screen view draws every carpet again, so "auto"
## steps down as views are added.
const LEVELS := {
	"high": [[0, 0.3, 0.0, 20.0, 1.0], [0, 0.7, 18.0, 60.0, 1.35], [0, 1.6, 52.0, 110.0, 2.0], [1, 0.55, 0.0, 30.0, 1.0]],
	"medium": [[0, 0.42, 0.0, 16.0, 1.1], [0, 0.9, 14.0, 45.0, 1.5], [0, 1.8, 40.0, 85.0, 2.1], [1, 0.75, 0.0, 22.0, 1.15]],
	"low": [[0, 0.6, 0.0, 32.0, 1.25], [0, 1.8, 28.0, 65.0, 2.0]],
}
# Nearest-cell camera snap contributes <=0.5 cell per axis; jitter <=0.8.
# sqrt(2)*(0.5+0.8)=1.839 cells bounds the offset-to-camera displacement.
# The full padded disk/annulus (including its bounding square) must exist.
const JITTER_STRENGTH := 1.6
const RING_PADDING_CELLS := 2.0
const GRASS := [Color(0.36, 0.46, 0.2), Color(0.62, 0.58, 0.36)]
const SHRUB := [Color(0.2, 0.32, 0.1), Color(0.52, 0.15, 0.07)] ## bilberry green, autumn red

static func build(parent: Node3D, ground: Image, origin: Vector2, detail := "high", views := 1) -> void:
	if detail == "auto":
		detail = "high" if views <= 1 else ("medium" if views == 2 else "low")
	var tex := ImageTexture.create_from_image(ground)
	RenderingServer.global_shader_parameter_set("ground_map", tex)
	RenderingServer.global_shader_parameter_set("ground_rect", Vector4(origin.x, origin.y, Stage.GRID, 0.0))
	var meshes := [_card_tuft(), _shrub()]
	# Keep the same photographed clump in both grass rings so the
	# silhouette does not change at their transition.
	var far_tuft: ArrayMesh = meshes[0]
	var carpets: Array = LEVELS.get(detail, LEVELS.medium)
	for c in carpets:
		var kind: int = c[0]
		var cell: float = c[1]
		var radius: float = c[3]
		var lo := maxf(float(c[2]) - 4.0 - cell * RING_PADDING_CELLS, 0.0)
		var hi := radius + cell * RING_PADDING_CELLS
		var extent := ceili(hi / cell)
		var offsets: Array[Vector3] = []
		for z in range(-extent, extent + 1):
			for x in range(-extent, extent + 1):
				var radius_squared := float(x * x + z * z) * cell * cell
				if radius_squared >= lo * lo and radius_squared <= hi * hi:
					offsets.append(Vector3(x * cell, 0.0, z * cell))
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = far_tuft if kind == 0 and float(c[2]) > 0.0 else meshes[kind]
		mm.instance_count = offsets.size()
		for i in offsets.size():
			mm.set_instance_transform(i, Transform3D(Basis(), offsets[i]))
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "GrassField" if kind == 0 else "Shrubs"
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# The grid is moved in the shader: never cull it.
		mmi.custom_aabb = AABB(Vector3(-1e5, -1e4, -1e5), Vector3(2e5, 2e4, 2e5))
		var mat := ShaderMaterial.new()
		mat.shader = preload("res://src/shaders/grass_cards.gdshader") if kind == 0 else preload("res://src/shaders/grass_field.gdshader")
		if kind == 0:
			mat.set_shader_parameter("grass_albedo", preload("res://assets/grass/grass_medium_01_diff_2k.jpg"))
			mat.set_shader_parameter("grass_alpha", preload("res://assets/grass/grass_medium_01_alpha_2k.png"))
		mat.set_shader_parameter("kind", kind)
		mat.set_shader_parameter("cell", cell)
		mat.set_shader_parameter("inner", c[2])
		mat.set_shader_parameter("radius", radius)
		mat.set_shader_parameter("grow", c[4])
		mat.set_shader_parameter("jitter_strength", JITTER_STRENGTH)
		# Adjacent carpets crossfade over their entire existing supported
		# overlap. No grid, tuft dimensions or instance budget changes.
		var enter_end := float(c[2])
		var next_begin := INF
		for other in carpets:
			if int(other[0]) != kind:
				continue
			if float(other[2]) < float(c[2]):
				enter_end = maxf(enter_end, float(other[3]))
			elif float(other[2]) > float(c[2]):
				next_begin = minf(next_begin, float(other[2]) - 4.0)
		mat.set_shader_parameter("coverage_in_end", enter_end)
		mat.set_shader_parameter("coverage_out_begin", radius * 0.7 if is_inf(next_begin) else next_begin)
		var colors: Array = GRASS if kind == 0 else SHRUB
		mat.set_shader_parameter("green", colors[0])
		mat.set_shader_parameter("dry", colors[1])
		mmi.material_override = mat
		mmi.set_meta("strip", "grass")
		parent.add_child(mmi)


## One photographed grass clump on three crossing cards. The original
## atlas stays unchanged: UV2 addresses its lower-right clump, while UV.y
## remains root-to-tip height for the existing wind and shading.
static func _card_tuft() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	const HEIGHT := 0.50
	const HALF_WIDTH := 0.36 * (257.0 / 135.0) * 0.5
	# Texel-centre coordinates from the original 1k layout, also valid at 2k.
	const ATLAS_MIN := Vector2(580.5 / 1024.0, 889.5 / 1024.0)
	const ATLAS_MAX := Vector2(836.5 / 1024.0, 1023.5 / 1024.0)
	for card in 3:
		var angle := PI * float(card) / 3.0
		var side := Vector3(cos(angle), 0.0, sin(angle)) * HALF_WIDTH
		var q := [-side, side, -side + Vector3.UP * HEIGHT, side + Vector3.UP * HEIGHT]
		var uv := [Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1)]
		for idx in [0, 2, 1, 1, 2, 3]:
			var logical_uv: Vector2 = uv[idx]
			st.set_uv(logical_uv)
			st.set_uv2(Vector2(
				lerpf(ATLAS_MIN.x, ATLAS_MAX.x, logical_uv.x),
				lerpf(ATLAS_MAX.y, ATLAS_MIN.y, logical_uv.y)))
			st.set_normal(Vector3.UP)
			st.add_vertex(q[idx])
	st.index()
	return st.commit()


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
static func _tuft(segments := 3) -> ArrayMesh:
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
		for k in segments + 1:
			var t := float(k) / segments
			var c := base + Vector3(0.0, h * t, 0.0) + lean * t * t
			var hw := w * (1.0 - t * 0.85)
			rows.append(PackedVector3Array([c - side * hw, c + side * hw]))
		for k in segments:
			var t0 := float(k) / segments
			var t1 := float(k + 1) / segments
			var q := [rows[k][0], rows[k][1], rows[k + 1][0], rows[k + 1][1]]
			var uv := [Vector2(0, t0), Vector2(1, t0), Vector2(0, t1), Vector2(1, t1)]
			for idx in [0, 2, 1, 1, 2, 3]:
				st.set_uv(uv[idx])
				st.set_normal(Vector3.UP)
				st.add_vertex(q[idx])
	st.index()
	return st.commit()
