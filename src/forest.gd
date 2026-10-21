class_name Forest
## Trees. The trees are three thinned variants of Poly Haven's
## fir_tree_01 (tools/thin_tree.py, tools/bake_trees.gd), each in a near mesh,
## a lighter mid mesh and a baked impostor (tools/bake_impostors.gd). They are
## grouped per block and per variant into MultiMeshes, and the visibility
## range of each instance swaps the level of detail.

const NEAR_BLOCK := 24.0
const MID_BLOCK := 48.0
const FAR_BLOCK := 160.0
const NEAR_END := 35.0
const MID_END := 100.0
const FAR_END := 900.0
const FADE := 12.0 ## metres over which two levels dissolve into each other
const BARK := preload("res://src/shaders/bark.gdshader")
const VARIANTS := ["a", "b", "c"]
## Height of each variant's impostor quad (the bake's orthographic size).
const IMPOSTOR_SIZE := [19.76, 17.03, 16.59]


static func build(parent: Node3D, spots: Array[Transform3D]) -> void:
	var near: Array[Mesh] = []
	var mid: Array[Mesh] = []
	var far: Array[Mesh] = []
	var shade: Array[Mesh] = []
	var atlas_albedo: Texture2D = load("res://assets/trees/impostor_albedo.png")
	var atlas_normal: Texture2D = load("res://assets/trees/impostor_normal.png")
	for v in VARIANTS.size():
		near.append(_faded(load("res://assets/trees/fir_%s_near.res" % VARIANTS[v]), -1.0, NEAR_END))
		mid.append(_faded(load("res://assets/trees/fir_%s_mid.res" % VARIANTS[v]), NEAR_END, MID_END))
		shade.append(_faded(load("res://assets/trees/fir_%s_mid.res" % VARIANTS[v]), -1.0, 1e6))
		var size: float = IMPOSTOR_SIZE[v]
		var quad := QuadMesh.new()
		quad.size = Vector2(size * 0.5, size)
		quad.center_offset = Vector3(0.0, size * 0.5, 0.0)
		var mat := ShaderMaterial.new()
		mat.shader = load("res://src/shaders/impostor.gdshader")
		mat.set_shader_parameter("albedo_atlas", atlas_albedo)
		mat.set_shader_parameter("normal_atlas", atlas_normal)
		mat.set_shader_parameter("row", v)
		mat.set_shader_parameter("fade_in_at", MID_END)
		mat.set_shader_parameter("fade_in_width", FADE * 2.0)
		quad.material = mat
		far.append(quad)
	# Every MultiMesh is culled once per view and per shadow split, so the
	# levels seen from further away come in bigger blocks: 30k small ones
	# were most of the CPU frame in split screen.
	var near_blocks := _blocks(spots, NEAR_BLOCK)
	var mid_blocks := _blocks(spots, MID_BLOCK)
	var far_blocks := _blocks(spots, FAR_BLOCK)
	# Ranges overlap by the fade width (plus most of the block size, since a
	# range is measured to the block, the fade to each tree).
	var near_pad := FADE + NEAR_BLOCK * 0.75
	var mid_pad := FADE * 2.0 + MID_BLOCK * 0.75
	for key in near_blocks:
		var list: Array = near_blocks[key]
		var v: int = key.z
		# The near trees (up to 16k triangles each) only draw; their shadow
		# comes from the light mid mesh, drawn into the shadow map alone.
		# Further out the canopy map (canopy.gd) shades the forest: every
		# tree in every shadow split, once per split-screen view, was most
		# of the frame.
		_instances(parent, near[v], list, 0.0, NEAR_END + near_pad, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
		_instances(parent, shade[v], list, 0.0, NEAR_END + near_pad, GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY)
	for key in mid_blocks:
		var v: int = key.z
		_instances(parent, mid[v], mid_blocks[key], maxf(NEAR_END - FADE - MID_BLOCK * 0.75, 0.0), MID_END + mid_pad, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	for key in far_blocks:
		var v: int = key.z
		_instances(parent, far[v], far_blocks[key], maxf(MID_END - FADE * 2.0 - FAR_BLOCK * 0.75, 0.0), FAR_END, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)


## The spots grouped per block of that size and per variant (the same
## variant for a spot in every grouping).
static func _blocks(spots: Array[Transform3D], size: float) -> Dictionary:
	var groups := {}
	for i in spots.size():
		var xf := spots[i]
		var key := Vector3i(floori(xf.origin.x / size), floori(xf.origin.z / size), (i * 7919 + 13) % 3)
		if not groups.has(key):
			groups[key] = []
		groups[key].append(xf)
	return groups


## A copy of a baked tree whose materials dissolve in and out at those
## distances (see lod_fade.gdshaderinc). Bark becomes the bark shader.
static func _faded(src: Mesh, fade_in: float, fade_out: float) -> Mesh:
	var mesh: Mesh = src.duplicate()
	for i in mesh.get_surface_count():
		var old := mesh.surface_get_material(i)
		var m: ShaderMaterial
		if old is ShaderMaterial:
			m = old.duplicate()
		else:
			var std := old as StandardMaterial3D
			m = ShaderMaterial.new()
			m.shader = BARK
			m.set_shader_parameter("albedo_tex", std.albedo_texture)
			m.set_shader_parameter("normal_tex", std.normal_texture)
			m.set_shader_parameter("triplanar", std.uv1_triplanar)
		m.set_shader_parameter("fade_in_at", fade_in)
		m.set_shader_parameter("fade_out_at", fade_out)
		m.set_shader_parameter("fade_in_width", FADE)
		m.set_shader_parameter("fade_out_width", FADE if fade_out <= NEAR_END else FADE * 2.0)
		mesh.surface_set_material(i, m)
	return mesh


static func _instances(parent: Node3D, mesh: Mesh, list: Array, begin: float, end: float, shadow: int) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = list.size()
	for j in list.size():
		mm.set_instance_transform(j, list[j])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.visibility_range_begin = begin
	mmi.visibility_range_end = end
	mmi.cast_shadow = shadow as GeometryInstance3D.ShadowCastingSetting
	mmi.set_meta("strip", "trees")
	parent.add_child(mmi)
