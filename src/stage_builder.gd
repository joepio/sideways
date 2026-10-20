class_name StageBuilder
## Turns a Stage into meshes and colliders: terrain chunks, the road ribbon,
## and where the trees go. Everything is plain arrays, so it can run on a
## worker thread while the menu or the previous round shows.

const TERRAIN_SHADER := preload("res://src/shaders/terrain.gdshader")
const ROAD_SHADER := preload("res://src/shaders/road.gdshader")

var stage: Stage
var terrain_material: ShaderMaterial
var road_material: ShaderMaterial
var tree_spots: Array[Transform3D] = []
var tree_colliders: Array[Vector3] = []
var rock_spots: Array[Transform3D] = []


func _init(s: Stage) -> void:
	stage = s
	terrain_material = ShaderMaterial.new()
	terrain_material.shader = TERRAIN_SHADER
	for key in ["leaves", "ground", "moss"]:
		var name: String = {"leaves": "forest_leaves_04", "ground": "forest_ground_04", "moss": "mossy_rock"}[key]
		terrain_material.set_shader_parameter(key + "_albedo", load("res://assets/textures/%s_albedo.jpg" % name))
		terrain_material.set_shader_parameter(key + "_normal", load("res://assets/textures/%s_normal.jpg" % name))
	road_material = ShaderMaterial.new()
	road_material.shader = ROAD_SHADER
	road_material.set_shader_parameter("gravel_albedo", load("res://assets/textures/gravel_ground_01_albedo.jpg"))
	road_material.set_shader_parameter("gravel_normal", load("res://assets/textures/gravel_ground_01_normal.jpg"))
	road_material.set_shader_parameter("gravel_rough", load("res://assets/textures/gravel_ground_01_rough.jpg"))
	road_material.set_shader_parameter("loose_albedo", load("res://assets/textures/forest_ground_04_albedo.jpg"))
	road_material.set_shader_parameter("loose_normal", load("res://assets/textures/forest_ground_04_normal.jpg"))


## The chunks of terrain within CORRIDOR of the road.
func chunks() -> Array[Vector2i]:
	var seen := {}
	var reach := int(ceil(Stage.CORRIDOR / Stage.CHUNK))
	for i in range(0, stage.points.size(), 8):
		var p := stage.points[i]
		var c := Vector2i(floori(p.x / Stage.CHUNK), floori(p.z / Stage.CHUNK))
		for dx in range(-reach, reach + 1):
			for dy in range(-reach, reach + 1):
				var k := c + Vector2i(dx, dy)
				if seen.has(k):
					continue
				var centre := (Vector2(k) + Vector2(0.5, 0.5)) * Stage.CHUNK
				if centre.distance_to(Vector2(p.x, p.z)) < Stage.CORRIDOR:
					seen[k] = true
	var out: Array[Vector2i] = []
	for k in seen:
		out.append(k)
	out.sort()
	return out


## One terrain chunk: mesh arrays plus the collision faces. Also collects
## tree spots. Vertices carry road distance in COLOR.r for the shader.
func terrain_chunk(c: Vector2i) -> Dictionary:
	var n := int(Stage.CHUNK / Stage.GRID) + 1
	var x0 := c.x * Stage.CHUNK
	var z0 := c.y * Stage.CHUNK
	var runs := stage.runs_near(x0, z0, Stage.CHUNK, 50.0)
	var guesses := PackedInt32Array()
	for r in runs:
		guesses.append(r[r.size() / 2])
	# Heights on a grid with one sample of padding, for normals.
	var m := n + 2
	var hs := PackedFloat32Array()
	hs.resize(m * m)
	var road_d := PackedFloat32Array()
	road_d.resize(m * m)
	for j in m:
		for i in m:
			var x := x0 + (i - 1) * Stage.GRID
			var z := z0 + (j - 1) * Stage.GRID
			var near := -1
			var near_d := INF
			for ri in runs.size():
				var g := _climb(x, z, guesses[ri], runs[ri][0], runs[ri][-1])
				guesses[ri] = g
				var d := Vector2(stage.points[g].x - x, stage.points[g].z - z).length_squared()
				if d < near_d:
					near_d = d
					near = g
			if near_d > 50.0 * 50.0:
				near = -1
			hs[j * m + i] = stage.height_near(x, z, near)
			road_d[j * m + i] = sqrt(near_d) - (stage.widths[near] if near >= 0 else 0.0)
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	verts.resize(n * n)
	normals.resize(n * n)
	colors.resize(n * n)
	for j in n:
		for i in n:
			var k := (j + 1) * m + (i + 1)
			var x := x0 + i * Stage.GRID
			var z := z0 + j * Stage.GRID
			verts[j * n + i] = Vector3(x, hs[k], z)
			var dx := hs[k + 1] - hs[k - 1]
			var dz := hs[k + m] - hs[k - m]
			normals[j * n + i] = Vector3(-dx, 2.0 * Stage.GRID, -dz).normalized()
			colors[j * n + i] = Color(clampf(road_d[k] / 14.0, 0.0, 1.0), 0.0, 0.0)
			# Trees: jittered grid, kept off the road and its ditches.
			if i < n - 1 and j < n - 1 and (i + j * 3) % 2 == 0:
				var tx := x + randf_range(0.0, Stage.GRID * 2.0)
				var tz := z + randf_range(0.0, Stage.GRID * 2.0)
				var clear: float = road_d[k] - randf_range(4.5, 9.0)
				var thin := stage._detail.get_noise_2d(tx * 0.6, tz * 0.6)
				if clear > 0.0 and thin > -0.25 and randf() < 0.28 + 0.25 * thin:
					var ty := stage.height(tx, tz)
					var s := randf_range(0.75, 1.25)
					var xf := Transform3D(Basis(Vector3.UP, randf() * TAU).scaled(Vector3(s, s * randf_range(0.9, 1.15), s)), Vector3(tx, ty - 0.1, tz))
					tree_spots.append(xf)
					if clear < 18.0:
						tree_colliders.append(Vector3(tx, ty, tz))
				elif clear > -3.0 and clear < 6.0 and randf() < 0.012:
					var ry := stage.height(tx, tz)
					var rs := randf_range(0.4, 1.3)
					rock_spots.append(Transform3D(Basis(Vector3(randf(), randf(), randf()).normalized(), randf() * TAU).scaled(Vector3(rs, rs * 0.7, rs)), Vector3(tx, ry - rs * 0.2, tz)))
	var idx := PackedInt32Array()
	for j in n - 1:
		for i in n - 1:
			var a := j * n + i
			idx.append_array([a, a + 1, a + n, a + 1, a + n + 1, a + n])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = idx
	var faces := PackedVector3Array()
	faces.resize(idx.size())
	for q in idx.size():
		faces[q] = verts[idx[q]]
	return {"arrays": arrays, "faces": faces}


func _climb(x: float, z: float, g: int, lo: int, hi: int) -> int:
	var d := _d2(x, z, g)
	while g < hi:
		var e := _d2(x, z, g + 1)
		if e >= d:
			break
		d = e
		g += 1
	while g > lo:
		var e := _d2(x, z, g - 1)
		if e >= d:
			break
		d = e
		g -= 1
	return g


func _d2(x: float, z: float, i: int) -> float:
	var p := stage.points[i]
	return (p.x - x) * (p.x - x) + (p.z - z) * (p.z - z)


## The road ribbon, from shoulder to shoulder. UV.x runs -1..1 across the
## driven width (beyond 1 is the loose edge), UV.y is metres along.
func road() -> Dictionary:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	var across := [-1.25, -1.0, -0.7, -0.35, 0.0, 0.35, 0.7, 1.0, 1.25]
	var cols := across.size()
	var n := stage.points.size()
	for i in n:
		var p := stage.points[i]
		var d := stage.dirs[i]
		var right := Vector3(-d.z, 0.0, d.x)
		var w := stage.widths[i]
		for a in across:
			var off: float = a * w
			if absf(a) > 1.1:
				off = signf(a) * (w + 0.8)
			var q := p + right * off
			var y := p.y - 0.06 * minf(absf(a), 1.0)
			if absf(a) > 1.1:
				y = stage.height_near(q.x, q.z, i) + 0.02
			verts.append(Vector3(q.x, y, q.z))
			normals.append(Vector3.UP)
			uvs.append(Vector2(a, i * Stage.STEP))
	# Normals from the surface itself.
	for i in n:
		for c in cols:
			var k := i * cols + c
			var along := verts[mini(k + cols, verts.size() - 1) if i < n - 1 else k] - verts[k - cols if i > 0 else k]
			var side := verts[k + 1 if c < cols - 1 else k] - verts[k - 1 if c > 0 else k]
			var nrm := side.cross(along).normalized()
			normals[k] = nrm if nrm.y > 0.0 else -nrm
	for i in n - 1:
		for c in cols - 1:
			var a := i * cols + c
			idx.append_array([a, a + cols, a + 1, a + 1, a + cols, a + cols + 1])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var faces := PackedVector3Array()
	faces.resize(idx.size())
	for q in idx.size():
		faces[q] = verts[idx[q]]
	return {"arrays": arrays, "faces": faces}


## Builds everything under `parent`. Returns the number of chunks.
func build(parent: Node3D) -> int:
	var list := chunks()
	var ground := StaticBody3D.new()
	ground.name = "Ground"
	ground.set_meta("surface", Surfaces.GRASS)
	parent.add_child(ground)
	for c in list:
		var data := terrain_chunk(c)
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, data.arrays)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = terrain_material
		mi.visibility_range_end = 900.0
		parent.add_child(mi)
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(data.faces)
		var cs := CollisionShape3D.new()
		cs.shape = shape
		ground.add_child(cs)
	var r := road()
	var road_mesh := ArrayMesh.new()
	road_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, r.arrays)
	var road_mi := MeshInstance3D.new()
	road_mi.name = "Road"
	road_mi.mesh = road_mesh
	road_mi.material_override = road_material
	parent.add_child(road_mi)
	var road_body := StaticBody3D.new()
	road_body.name = "RoadBody"
	road_body.set_meta("road", true)
	var road_shape := ConcavePolygonShape3D.new()
	road_shape.set_faces(r.faces)
	var road_cs := CollisionShape3D.new()
	road_cs.shape = road_shape
	road_body.add_child(road_cs)
	parent.add_child(road_body)
	# Tree trunks near the road stop cars.
	var trees := StaticBody3D.new()
	trees.name = "Trunks"
	trees.set_meta("surface", Surfaces.DIRT)
	var trunk := CylinderShape3D.new()
	trunk.radius = 0.22
	trunk.height = 6.0
	for p in tree_colliders:
		var cs := CollisionShape3D.new()
		cs.shape = trunk
		cs.position = p + Vector3.UP * 2.5
		trees.add_child(cs)
	parent.add_child(trees)
	return list.size()
