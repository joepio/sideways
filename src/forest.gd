class_name Forest
## Trees and rocks, drawn as MultiMeshes grouped per 128 m block so blocks
## out of view or out of range are culled. Spruce and Scots pine meshes are
## built in code for now.

const BLOCK := 128.0


static func build(parent: Node3D, spots: Array[Transform3D], rocks: Array[Transform3D]) -> void:
	var spruce := _spruce()
	var pine := _pine()
	var groups := {}
	for i in spots.size():
		var xf := spots[i]
		var key := Vector3i(floori(xf.origin.x / BLOCK), floori(xf.origin.z / BLOCK), 1 if (i * 7919) % 10 < 4 else 0)
		if not groups.has(key):
			groups[key] = []
		groups[key].append(xf)
	for key in groups:
		var list: Array = groups[key]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = pine if key.z == 1 else spruce
		mm.instance_count = list.size()
		for j in list.size():
			mm.set_instance_transform(j, list[j])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.visibility_range_end = 650.0
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		parent.add_child(mmi)
	if rocks.is_empty():
		return
	var rock_mesh := _rock()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = rock_mesh
	mm.instance_count = rocks.size()
	for j in rocks.size():
		mm.set_instance_transform(j, rocks[j])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.visibility_range_end = 300.0
	parent.add_child(mmi)


static func _bark() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.28, 0.2, 0.15)
	m.roughness = 0.95
	return m


static func _needles(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.9
	m.vertex_color_use_as_albedo = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


## A spruce: dark cone of drooping tiers down to the ground.
static func _spruce() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_cylinder(st, 0.22, 0.05, 0.0, 17.0, 6)
	var mesh := st.commit()
	st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tiers := 9
	for t in tiers:
		var f := float(t) / tiers
		var y0 := 1.2 + f * 15.0
		var r := lerpf(2.6, 0.4, f)
		var h := lerpf(3.2, 1.6, f)
		var shade := lerpf(0.55, 1.0, f)
		_cone(st, r, y0, y0 + h, 11, Color(0.10, 0.17, 0.09) * shade, f * 3.3)
	st.generate_normals()
	st.set_material(_needles(Color.WHITE))
	st.commit(mesh)
	mesh.surface_set_material(0, _bark())
	return mesh


## A Scots pine: tall bare orange-brown trunk, crown at the top.
static func _pine() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_cylinder(st, 0.26, 0.12, 0.0, 15.0, 7)
	var mesh := st.commit()
	var bark := _bark()
	bark.albedo_color = Color(0.45, 0.27, 0.16)
	mesh.surface_set_material(0, bark)
	st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for b in 7:
		var y := 11.0 + b * 0.9
		var r := 2.2 - b * 0.22
		_blob(st, Vector3(sin(b * 2.4) * 0.8, y, cos(b * 2.4) * 0.8), r, Color(0.14, 0.22, 0.10) * (0.7 + 0.05 * b))
	st.generate_normals()
	st.set_material(_needles(Color.WHITE))
	st.commit(mesh)
	return mesh


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


static func _cylinder(st: SurfaceTool, r0: float, r1: float, y0: float, y1: float, sides: int) -> void:
	for i in sides:
		var a0 := TAU * i / sides
		var a1 := TAU * (i + 1) / sides
		var p0 := Vector3(cos(a0) * r0, y0, sin(a0) * r0)
		var p1 := Vector3(cos(a1) * r0, y0, sin(a1) * r0)
		var q0 := Vector3(cos(a0) * r1, y1, sin(a0) * r1)
		var q1 := Vector3(cos(a1) * r1, y1, sin(a1) * r1)
		st.set_normal(Vector3(cos(a0), 0, sin(a0)))
		st.add_vertex(p0)
		st.add_vertex(q0)
		st.add_vertex(p1)
		st.add_vertex(p1)
		st.add_vertex(q0)
		st.add_vertex(q1)


static func _cone(st: SurfaceTool, r: float, y0: float, y1: float, sides: int, c: Color, twist: float) -> void:
	var tip := Vector3(0, y1, 0)
	for i in sides:
		var a0 := TAU * i / sides + twist
		var a1 := TAU * (i + 1) / sides + twist
		# Ragged edge: every other point droops and sticks out.
		var r0 := r * (1.0 if i % 2 == 0 else 0.78)
		var r1 := r * (1.0 if (i + 1) % 2 == 0 else 0.78)
		var d0 := -0.35 if i % 2 == 0 else 0.0
		var d1 := -0.35 if (i + 1) % 2 == 0 else 0.0
		st.set_color(c * 0.8)
		st.add_vertex(Vector3(cos(a0) * r0, y0 + d0, sin(a0) * r0))
		st.set_color(c * 1.15)
		st.add_vertex(tip)
		st.set_color(c * 0.8)
		st.add_vertex(Vector3(cos(a1) * r1, y0 + d1, sin(a1) * r1))


static func _blob(st: SurfaceTool, centre: Vector3, r: float, c: Color) -> void:
	var sphere := SphereMesh.new()
	sphere.radius = r
	sphere.height = r * 1.1
	sphere.radial_segments = 8
	sphere.rings = 4
	var arr := sphere.get_mesh_arrays()
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	for i in idx:
		var v := verts[i]
		st.set_color(c * (0.8 + 0.4 * clampf(v.y / r + 0.5, 0.0, 1.0)))
		st.add_vertex(centre + v)
