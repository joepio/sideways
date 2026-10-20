class_name Forest
## Trees and rocks. The trees are three thinned variants of Poly Haven's
## fir_tree_01 (tools/thin_tree.py, tools/bake_trees.gd), each in a near mesh,
## a lighter mid mesh and a baked impostor (tools/bake_impostors.gd). They are
## grouped per block and per variant into MultiMeshes, and the visibility
## range of each instance swaps the level of detail.

const BLOCK := 48.0
const NEAR_END := 45.0
const MID_END := 120.0
const FAR_END := 900.0
const VARIANTS := ["a", "b", "c"]
## Height of each variant's impostor quad (the bake's orthographic size).
const IMPOSTOR_SIZE := [19.76, 17.03, 16.59]


static func build(parent: Node3D, spots: Array[Transform3D], rocks: Array[Transform3D]) -> void:
	var near: Array[Mesh] = []
	var mid: Array[Mesh] = []
	var far: Array[Mesh] = []
	var atlas_albedo: Texture2D = load("res://assets/trees/impostor_albedo.png")
	var atlas_normal: Texture2D = load("res://assets/trees/impostor_normal.png")
	for v in VARIANTS.size():
		near.append(load("res://assets/trees/fir_%s_near.res" % VARIANTS[v]))
		mid.append(load("res://assets/trees/fir_%s_mid.res" % VARIANTS[v]))
		var size: float = IMPOSTOR_SIZE[v]
		var quad := QuadMesh.new()
		quad.size = Vector2(size * 0.5, size)
		quad.center_offset = Vector3(0.0, size * 0.5, 0.0)
		var mat := ShaderMaterial.new()
		mat.shader = load("res://src/shaders/impostor.gdshader")
		mat.set_shader_parameter("albedo_atlas", atlas_albedo)
		mat.set_shader_parameter("normal_atlas", atlas_normal)
		mat.set_shader_parameter("row", v)
		quad.material = mat
		far.append(quad)
	var groups := {}
	for i in spots.size():
		var xf := spots[i]
		var key := Vector3i(floori(xf.origin.x / BLOCK), floori(xf.origin.z / BLOCK), (i * 7919 + 13) % 3)
		if not groups.has(key):
			groups[key] = []
		groups[key].append(xf)
	for key in groups:
		var list: Array = groups[key]
		var v: int = key.z
		_instances(parent, near[v], list, 0.0, NEAR_END, GeometryInstance3D.SHADOW_CASTING_SETTING_ON)
		_instances(parent, mid[v], list, NEAR_END, MID_END, GeometryInstance3D.SHADOW_CASTING_SETTING_ON)
		_instances(parent, far[v], list, MID_END, FAR_END, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	if rocks.is_empty():
		return
	_instances(parent, _rock(), rocks, 0.0, 300.0, GeometryInstance3D.SHADOW_CASTING_SETTING_ON)


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
	parent.add_child(mmi)


static func _rock() -> ArrayMesh:
	var mesh := SphereMesh.new()
	mesh.radial_segments = 8
	mesh.rings = 5
	mesh.radius = 1.0
	mesh.height = 1.4
	var m := StandardMaterial3D.new()
	m.albedo_texture = load("res://assets/textures/mossy_rock_albedo.jpg")
	m.normal_enabled = true
	m.normal_texture = load("res://assets/textures/mossy_rock_normal.jpg")
	m.uv1_triplanar = true
	m.uv1_scale = Vector3(0.5, 0.5, 0.5)
	mesh.material = m
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, mesh.get_mesh_arrays())
	am.surface_set_material(0, m)
	return am
