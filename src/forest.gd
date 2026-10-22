class_name Forest
## Trees combine retained Poly Haven fir_tree_01 wood with authored Pine Tree
## crowns by evolveduk (CC BY 4.0; see CREDITS.md and tools/pine_crown_data).
## Each variant has near/mid meshes and a matching paired impostor. Near and
## mid trees come in a set per view (tree_sets.gd), impostors in blocks with
## a visibility range; the trees' shaders dissolve one level into the next.

const FAR_BLOCK := 320.0
const NEAR_END := 25.0
const MID_END := 70.0
const FAR_END := 900.0
const FADE := 8.0 ## metres over which two levels dissolve into each other
const BARK := preload("res://src/shaders/bark.gdshader")
const VARIANTS := ["a", "b", "c"]
## Height of each variant's impostor quad (the bake's orthographic size).
const IMPOSTOR_SIZE := [18.90518, 14.06178, 14.77670]


static func build(parent: Node3D, spots: Array[Transform3D], views := 1) -> TreeSets:
	# Quarter-screen trees occupy fewer pixels. Keep the close silhouette
	# and the same dissolve widths, but use the existing lighter meshes sooner.
	var detail_scale := 0.75 if views >= 3 else 1.0
	var near_end := NEAR_END * detail_scale
	var mid_end := MID_END * detail_scale
	var near: Array[Mesh] = []
	var mid: Array[Mesh] = []
	var far: Array[Mesh] = []
	var shade: Array[Mesh] = []
	var atlas_albedo: Texture2D = load("res://assets/trees/impostor_albedo.png")
	var atlas_normal: Texture2D = load("res://assets/trees/impostor_normal.png")
	for v in VARIANTS.size():
		near.append(_faded(load("res://assets/trees/fir_%s_near.res" % VARIANTS[v]), -1.0, near_end))
		mid.append(_faded(load("res://assets/trees/fir_%s_mid.res" % VARIANTS[v]), near_end, mid_end))
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
		mat.set_shader_parameter("fade_in_at", mid_end)
		mat.set_shader_parameter("fade_in_width", FADE * 2.0)
		quad.material = mat
		far.append(quad)
	# Near and mid trees: a small set per view, refilled as its camera
	# moves (tree_sets.gd). Near trees only draw; their shadow comes from
	# the mid mesh, which shares the authored crown but retains simpler
	# wood. Further out the canopy map (canopy.gd) shades the forest.
	var sets := TreeSets.new()
	sets.name = "TreeSets"
	sets.near_end = near_end
	sets.mid_end = mid_end
	var sun := Look.sun_direction()
	var away := -Vector2(sun.x, sun.z).normalized()
	sets.shadow_tip = away * 21.0 * Vector2(sun.x, sun.z).length() / maxf(sun.y, 0.15)
	for v in VARIANTS.size():
		sets.meshes.append([near[v], shade[v], mid[v]])
	var variant := PackedInt32Array()
	variant.resize(spots.size())
	for i in spots.size():
		variant[i] = _variant(i)
	sets.setup(spots, variant)
	parent.add_child(sets)
	# The impostors: few draws, so blocks with a visibility range. Every
	# MultiMesh is culled once per view and per shadow split.
	var far_blocks := _blocks(spots, FAR_BLOCK)
	for key in far_blocks:
		var v: int = key.z
		_instances(parent, far[v], far_blocks[key], maxf(mid_end - FADE * 2.0 - FAR_BLOCK * 0.75, 0.0), FAR_END, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	return sets


static func _variant(i: int) -> int:
	return (i * 7919 + 13) % VARIANTS.size()


## The spots grouped per block of that size and per variant (the same
## variant for a spot in every grouping).
static func _blocks(spots: Array[Transform3D], size: float) -> Dictionary:
	var groups := {}
	for i in spots.size():
		var xf := spots[i]
		var key := Vector3i(floori(xf.origin.x / size), floori(xf.origin.z / size), _variant(i))
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
