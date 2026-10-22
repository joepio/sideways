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
var tree_colliders: Array[Transform3D] = []
var rock_spots: Array[Transform3D] = []
var grass_spots: Array[Transform3D] = [] ## grass tufts: thick on the verge, sparse in the wood
var fern_spots: Array[Transform3D] = []
var stump_spots: Array[Transform3D] = []
## Height (R), distance from the road edge (G), how level it is (B, the
## normal's y) and water depth (A) every GRID metres over all
## the terrain, for shaders that need the ground (the grass field).
var ground_map: Image
var ground_origin := Vector2.ZERO


func _init(s: Stage) -> void:
	stage = s
	terrain_material = ShaderMaterial.new()
	terrain_material.shader = TERRAIN_SHADER
	var layers := {"moss": "forest_leaves_02", "needles": "forrest_ground_03", "verge": "grass_ground", "ground": "forest_ground_04", "rock": "rock_face_03"}
	for key in layers:
		var name: String = layers[key]
		terrain_material.set_shader_parameter(key + "_albedo", load("res://assets/textures/%s_albedo.jpg" % name))
		terrain_material.set_shader_parameter(key + "_normal", load("res://assets/textures/%s_normal.jpg" % name))
	road_material = ShaderMaterial.new()
	road_material.shader = ROAD_SHADER
	road_material.set_shader_parameter("road_surface_map", ImageTexture.create_from_image(stage.road_surface_image()))
	road_material.set_shader_parameter("road_surface_step", Stage.STEP)
	road_material.set_shader_parameter("gravel_albedo", load("res://assets/textures/gravel_ground_01_albedo.jpg"))
	road_material.set_shader_parameter("gravel_normal", load("res://assets/textures/gravel_ground_01_normal.jpg"))
	road_material.set_shader_parameter("gravel_rough", load("res://assets/textures/gravel_ground_01_rough.jpg"))
	road_material.set_shader_parameter("gravel_height", load("res://assets/textures/gravel_ground_01_disp.jpg"))
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
	# Its own random numbers and lists, so chunks can be built in parallel
	# and still come out the same.
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([stage._noise.seed, c.x, c.y])
	var trees: Array[Transform3D] = []
	var colliders: Array[Transform3D] = []
	var rocks: Array[Transform3D] = []
	var grass: Array[Transform3D] = []
	var ferns: Array[Transform3D] = []
	var stumps: Array[Transform3D] = []
	var n := int(Stage.CHUNK / Stage.GRID) + 1
	var x0 := c.x * Stage.CHUNK
	var z0 := c.y * Stage.CHUNK
	var runs := stage.runs_near(x0, z0, Stage.CHUNK, Stage.REACH + 5.0)
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
			if near_d > Stage.REACH * Stage.REACH:
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
			# Rock faces and stream beds: nothing grows.
			var steep := normals[j * n + i].y < 0.75 or (not stage.rivers.is_empty() and stage.water_level(x, z) > hs[k] - 0.4)
			colors[j * n + i] = Color(clampf(road_d[k] / 14.0, 0.0, 1.0), 0.0, 0.0)
			# Grass tufts: thick on the verge, then thinning into the wood.
			var edge: float = road_d[k]
			if i < n - 1 and j < n - 1 and edge > 0.7 and edge < 26.0 and not steep:
				var tufts := 7 if edge < 9.0 else (2 if rng.randf() < 0.5 else 0)
				# In clumps, as grass grows: a centre and tufts round it.
				var cx := x + rng.randf() * Stage.GRID
				var cz := z + rng.randf() * Stage.GRID
				for _t in tufts:
					var gx := clampf(cx + rng.randf_range(-0.6, 0.6), x, x + Stage.GRID)
					var gz := clampf(cz + rng.randf_range(-0.6, 0.6), z, z + Stage.GRID)
					var gs := rng.randf_range(0.6, 1.2) * (1.0 if edge < 9.0 else 0.75)
					# Height from this chunk's own grid: much cheaper than a road lookup.
					var fx := (gx - x) / Stage.GRID
					var fz := (gz - z) / Stage.GRID
					var gy := lerpf(lerpf(hs[k], hs[k + 1], fx), lerpf(hs[k + m], hs[k + m + 1], fx), fz)
					grass.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(gs, gs * rng.randf_range(0.8, 1.3), gs)), Vector3(gx, gy - 0.03, gz)))
			# Trees: jittered grid, kept off the road and its ditches.
			if i < n - 1 and j < n - 1 and (i + j * 3) % 2 == 0:
				var tx := x + rng.randf_range(0.0, Stage.GRID * 2.0)
				var tz := z + rng.randf_range(0.0, Stage.GRID * 2.0)
				var clear: float = road_d[k] - rng.randf_range(4.5, 9.0)
				var thin := stage._detail.get_noise_2d(tx * 0.6, tz * 0.6)
				if clear > 0.0 and not steep and thin > -0.25 and rng.randf() < 0.28 + 0.25 * thin:
					var ty := stage.height(tx, tz)
					# Stand on the lowest ground round the trunk, a little sunk:
					# on a slope (and on the coarser drawn terrain) the centre
					# alone left trees floating.
					var foot := ty
					for o in [Vector2(0.7, 0.0), Vector2(-0.7, 0.0), Vector2(0.0, 0.7), Vector2(0.0, -0.7)]:
						foot = minf(foot, stage.height(tx + o.x, tz + o.y))
					var s := rng.randf_range(0.75, 1.25)
					var xf := Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * rng.randf_range(0.9, 1.15), s)), Vector3(tx, foot - 0.25, tz))
					trees.append(xf)
					# Every visible tree is solid, including off-road trees. Reuse
					# the drawn foot/scale and consume no additional random values.
					colliders.append(xf)
				elif clear > 4.0 and not steep and rng.randf() < 0.004:
					var sy := stage.height(tx, tz)
					var ss := rng.randf_range(0.8, 1.3)
					stumps.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(ss, ss, ss)), Vector3(tx, sy - 0.05, tz)))
				elif clear > 3.0 and not steep and rng.randf() < 0.05 + 0.08 * maxf(thin, 0.0):
					var fy := stage.height(tx, tz)
					var fs := rng.randf_range(0.7, 1.3)
					ferns.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(fs, fs, fs)), Vector3(tx, fy - 0.05, tz)))
				elif clear > -3.0 and clear < 6.0 and rng.randf() < 0.012:
					var ry := stage.height(tx, tz)
					var rs := rng.randf_range(0.4, 1.3)
					rocks.append(Transform3D(Basis(Vector3(rng.randf(), rng.randf(), rng.randf()).normalized(), rng.randf() * TAU).scaled(Vector3(rs, rs * 0.7, rs)), Vector3(tx, ry - rs * 0.2, tz)))
	var idx := PackedInt32Array()
	for j in n - 1:
		for i in n - 1:
			var a := j * n + i
			idx.append_array([a, a + 1, a + n, a + 1, a + n + 1, a + n])
	var arrays := _fine_mesh(n, verts, normals, colors, road_d, m)
	_skirt(arrays)
	var coarse := [_coarse_mesh(n, verts, normals, colors, 2), _coarse_mesh(n, verts, normals, colors, 4)]
	var faces := PackedVector3Array()
	faces.resize(idx.size())
	for q in idx.size():
		faces[q] = verts[idx[q]]
	return {"arrays": arrays, "coarse": coarse, "faces": faces, "hs": hs, "road_d": road_d, "m": m, "x0": x0, "z0": z0,
		"trees": trees, "colliders": colliders, "rocks": rocks, "grass": grass, "ferns": ferns, "stumps": stumps}


## Seen from further away a chunk draws every `step`th grid line (4 m, then
## 8 m). It is exact on its own vertices; where it meets a finer neighbour
## the skirts close the seam.
func _coarse_mesh(n: int, verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, step: int) -> Array:
	var c := (n - 1) / step + 1
	var v := PackedVector3Array()
	var nn := PackedVector3Array()
	var cc := PackedColorArray()
	for j in c:
		for i in c:
			var k := j * step * n + i * step
			v.append(verts[k])
			nn.append(normals[k])
			cc.append(colors[k])
	var idx := PackedInt32Array()
	for j in c - 1:
		for i in c - 1:
			var a := j * c + i
			idx.append_array([a, a + 1, a + c, a + 1, a + c + 1, a + c])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_NORMAL] = nn
	arrays[Mesh.ARRAY_COLOR] = cc
	arrays[Mesh.ARRAY_INDEX] = idx
	_skirt(arrays)
	return arrays


const SKIRT := 1.5 ## metres the chunk edges hang down, over seams between levels

## Hangs a strip below each edge of a chunk mesh, both faces drawn, so a
## coarser neighbour's edge (straight between its vertices) leaves no gap.
func _skirt(arrays: Array) -> void:
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var nn: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var cc: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in v:
		lo = lo.min(Vector2(p.x, p.z))
		hi = hi.max(Vector2(p.x, p.z))
	# The four edges, each as its vertices sorted along it.
	var edges := [[], [], [], []]
	for k in v.size():
		var p := v[k]
		if is_equal_approx(p.z, lo.y):
			edges[0].append([p.x, k])
		if is_equal_approx(p.z, hi.y):
			edges[1].append([p.x, k])
		if is_equal_approx(p.x, lo.x):
			edges[2].append([p.z, k])
		if is_equal_approx(p.x, hi.x):
			edges[3].append([p.z, k])
	for e in edges:
		e.sort_custom(func(a, b): return a[0] < b[0])
		var below := PackedInt32Array()
		for item in e:
			var k: int = item[1]
			below.append(v.size())
			v.append(v[k] - Vector3(0.0, SKIRT, 0.0))
			nn.append(nn[k])
			cc.append(cc[k])
		for q in e.size() - 1:
			var a: int = e[q][1]
			var b: int = e[q + 1][1]
			var a2 := below[q]
			var b2 := below[q + 1]
			idx.append_array([a, b, a2, b, b2, a2, a, a2, b, b, a2, b2])
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_NORMAL] = nn
	arrays[Mesh.ARRAY_COLOR] = cc
	arrays[Mesh.ARRAY_INDEX] = idx


## The drawn terrain: the 2 m grid, with the cells near the road split
## SPLIT x SPLIT so the shader's relief (relief.gdshaderinc) has vertices to
## move. The new vertices lie on the coarse cells (bilinear), so the edges
## against unsplit cells match, and the colliders keep the coarse grid.
const SPLIT := 3
const TERRAIN_LOD := [150.0, 360.0, 900.0] ## where the 2 m, 4 m and 8 m chunks end
const TRUNK_BLOCK := 32.0 ## metres: trunk colliders are grouped per block
const FINE_REACH := 15.0 ## metres from the road edge


func _fine_mesh(n: int, verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, road_d: PackedFloat32Array, m: int) -> Array:
	var f := FineMesh.new()
	f.n = n
	f.l = (n - 1) * SPLIT + 1
	f.verts = verts
	f.normals = normals
	f.colors = colors
	f.map.resize(f.l * f.l)
	f.map.fill(-1)
	var idx := PackedInt32Array()
	for j in n - 1:
		for i in n - 1:
			var k := (j + 1) * m + (i + 1)
			var near := minf(minf(road_d[k], road_d[k + 1]), minf(road_d[k + m], road_d[k + m + 1]))
			var far := maxf(maxf(road_d[k], road_d[k + 1]), maxf(road_d[k + m], road_d[k + m + 1]))
			var s := SPLIT if near < FINE_REACH and far > 0.0 else 1
			var step := SPLIT / s
			for b in s:
				for q in s:
					var li := i * SPLIT + q * step
					var lj := j * SPLIT + b * step
					var v00 := f.at(li, lj)
					var v10 := f.at(li + step, lj)
					var v01 := f.at(li, lj + step)
					var v11 := f.at(li + step, lj + step)
					idx.append_array([v00, v10, v01, v10, v11, v01])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = f.out_v
	arrays[Mesh.ARRAY_NORMAL] = f.out_n
	arrays[Mesh.ARRAY_COLOR] = f.out_c
	arrays[Mesh.ARRAY_INDEX] = idx
	return arrays


## Lattice vertices of one chunk, made once each on first use.
class FineMesh:
	var n: int
	var l: int
	var verts: PackedVector3Array
	var normals: PackedVector3Array
	var colors: PackedColorArray
	var map := PackedInt32Array()
	var out_v := PackedVector3Array()
	var out_n := PackedVector3Array()
	var out_c := PackedColorArray()

	func at(li: int, lj: int) -> int:
		var key := lj * l + li
		if map[key] >= 0:
			return map[key]
		var ci := mini(li / SPLIT, n - 2)
		var cj := mini(lj / SPLIT, n - 2)
		var u := float(li - ci * SPLIT) / SPLIT
		var v := float(lj - cj * SPLIT) / SPLIT
		var a := cj * n + ci
		map[key] = out_v.size()
		out_v.append(verts[a].lerp(verts[a + 1], u).lerp(verts[a + n].lerp(verts[a + n + 1], u), v))
		out_n.append(normals[a].lerp(normals[a + 1], u).lerp(normals[a + n].lerp(normals[a + n + 1], u), v).normalized())
		out_c.append(colors[a].lerp(colors[a + 1], u).lerp(colors[a + n].lerp(colors[a + n + 1], u), v))
		return map[key]


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
	var road_axes := PackedVector2Array()
	var idx := PackedInt32Array()
	var colors := PackedColorArray()
	# Dense across the driven width so the wheel tracks, the loose ridge
	# between them and the gravel windrows at the edges are real shape (the
	# road collider is this mesh, so the tyres feel them too).
	var across := [-1.25, -1.0, -0.86, -0.72, -0.58, -0.46, -0.36, -0.28, -0.21, -0.14, -0.07, 0.0,
		0.07, 0.14, 0.21, 0.28, 0.36, 0.46, 0.58, 0.72, 0.86, 1.0, 1.25]
	var cols := across.size()
	var n := stage.points.size()
	var wob := FastNoiseLite.new()
	wob.seed = 11
	wob.frequency = 1.0 / 18.0
	for i in n:
		var p := stage.points[i]
		var d := stage.dirs[i]
		var right := Vector3(-d.z, 0.0, d.x)
		var w := stage.widths[i]
		# The tracks wander a little and are deeper where the road is worn.
		var wander := wob.get_noise_1d(i * Stage.STEP) * 0.08
		var wear := 0.6 + 0.4 * wob.get_noise_1d(i * Stage.STEP * 0.3 + 100.0)
		for a in across:
			var off: float = a * w
			if absf(a) > 1.1:
				off = signf(a) * (w + 0.8)
			var q := p + right * off
			var y := p.y - 0.06 * minf(absf(a), 1.0)
			var rut := exp(-pow((absf(a + wander) - 0.25) / 0.085, 2.0)) * wear
			var ridge := exp(-pow((a + wander) / 0.07, 2.0)) * wear
			var windrow := exp(-pow((absf(a) - 0.8) / 0.08, 2.0))
			y += -0.045 * rut + 0.025 * ridge + 0.04 * windrow
			if absf(a) > 1.1:
				y = stage.height_near(q.x, q.z, i) + 0.02
			verts.append(Vector3(q.x, y, q.z))
			normals.append(Vector3.UP)
			uvs.append(Vector2(a, i * Stage.STEP))
			road_axes.append(Vector2(right.x, right.z))
			colors.append(Color(rut, ridge, windrow))
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
	arrays[Mesh.ARRAY_TEX_UV2] = road_axes
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = idx
	var faces := PackedVector3Array()
	faces.resize(idx.size())
	for q in idx.size():
		faces[q] = verts[idx[q]]
	# The road and terrain have different sampling grids. A paper-thin
	# outside edge could expose daylight where their interpolated heights
	# diverged. Close that edge with soil, without changing the driven mesh
	# or its collision faces. Bridges keep their deliberately open sides.
	_road_shoulders(arrays, n, cols)
	return {"arrays": arrays, "faces": faces}


func _road_shoulders(arrays: Array, rows: int, cols: int) -> void:
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var nn: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var axes: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
	var cc: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var bridge_rows := {}
	for river in stage.rivers:
		if not river.ford:
			var reach := ceili((float(river.half) + 6.0) / Stage.STEP)
			for row in range(maxi(0, int(river.cross) - reach), mini(rows, int(river.cross) + reach + 1)):
				bridge_rows[row] = true
	for edge in [0, cols - 1]:
		var first := v.size()
		for row in rows:
			var k: int = row * cols + edge
			var top := v[k]
			var outward := Vector3(top.x - stage.points[row].x, 0.0, top.z - stage.points[row].z).normalized()
			# Bury the lower edge beyond the small grid mismatch. The narrow
			# wedge reads as earth under the verge, not a vertical sheet.
			var bottom := top + outward * 0.25 - Vector3.UP * 1.5
			v.append(top)
			v.append(bottom)
			nn.append(outward)
			nn.append(outward)
			uv.append(uv[k])
			uv.append(uv[k] + Vector2(0.0, 0.3))
			axes.append(axes[k])
			axes.append(axes[k])
			cc.append(cc[k])
			cc.append(cc[k])
		for row in rows - 1:
			if bridge_rows.has(row) or bridge_rows.has(row + 1):
				continue
			var a: int = first + row * 2
			var b: int = a + 2
			idx.append_array([a, b, a + 1, b, b + 1, a + 1, a, a + 1, b, b, a + 1, b + 1])
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_NORMAL] = nn
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_TEX_UV2] = axes
	arrays[Mesh.ARRAY_COLOR] = cc
	arrays[Mesh.ARRAY_INDEX] = idx


func _to_ground_map(cell: Vector2i, data: Dictionary) -> void:
	var per := int(Stage.CHUNK / Stage.GRID)
	var m: int = data.m
	var hs: PackedFloat32Array = data.hs
	var rd: PackedFloat32Array = data.road_d
	for j in per + 1:
		for i in per + 1:
			var k := (j + 1) * m + (i + 1)
			var up := Vector3(hs[k - 1] - hs[k + 1], 2.0 * Stage.GRID, hs[k - m] - hs[k + m]).normalized().y
			var wx: float = data.x0 + i * Stage.GRID
			var wz: float = data.z0 + j * Stage.GRID
			var wet := 0.0
			if not stage.rivers.is_empty():
				wet = maxf(stage.water_level(wx, wz) - hs[k], 0.0)
			ground_map.set_pixel(cell.x * per + i, cell.y * per + j, Color(hs[k], minf(rd[k], 999.0), up, wet))


## Builds everything under `parent`. Returns the number of chunks.
func build(parent: Node3D, progress: Callable = Callable(), yield_frames := false) -> int:
	var list := chunks()
	# Colliders go in one static body per chunk or block, not one body for
	# the whole stage: a car overlaps a stage-wide body all the time, and
	# Jolt then tests it against every shape in it on every physics step.
	var ground := Node3D.new()
	ground.name = "Ground"
	parent.add_child(ground)
	var lo := list[0]
	var hi := list[0]
	for c in list:
		lo = lo.min(c)
		hi = hi.max(c)
	var per := int(Stage.CHUNK / Stage.GRID)
	ground_origin = Vector2(lo) * Stage.CHUNK
	ground_map = Image.create_empty((hi.x - lo.x + 1) * per + 1, (hi.y - lo.y + 1) * per + 1, false, Image.FORMAT_RGBAF)
	# Outside the terrain: far below and far from the road, so nothing grows.
	ground_map.fill(Color(-1000.0, 999.0, 0.0, 0.0))
	# The chunks are independent: build them on all cores.
	var built: Array[Dictionary] = []
	built.resize(list.size())
	var task := WorkerThreadPool.add_group_task(func(k: int) -> void: built[k] = terrain_chunk(list[k]), list.size(), -1, true, "terrain")
	if progress.is_valid():
		progress.call("Generating terrain", 0, list.size())
	if yield_frames:
		while not WorkerThreadPool.is_group_task_completed(task):
			if progress.is_valid():
				progress.call("Generating terrain", WorkerThreadPool.get_group_processed_element_count(task), list.size())
			await parent.get_tree().process_frame
	# Even an already completed group must be waited for to release its pool data.
	WorkerThreadPool.wait_for_group_task_completion(task)
	if progress.is_valid():
		progress.call("Preparing terrain", 0, list.size())
	var slice_start := Time.get_ticks_usec()
	for ci in list.size():
		var c := list[ci]
		var data := built[ci]
		tree_spots.append_array(data.trees)
		tree_colliders.append_array(data.colliders)
		rock_spots.append_array(data.rocks)
		grass_spots.append_array(data.grass)
		fern_spots.append_array(data.ferns)
		stump_spots.append_array(data.stumps)
		_to_ground_map(c - lo, data)
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, data.arrays)
		# Fine near the cameras, then every second and every fourth grid
		# line: the far chunks at the full 2 m grid were a fifth of the
		# triangles in each view.
		var levels: Array = [[mesh, 0.0, TERRAIN_LOD[0]]]
		for li in data.coarse.size():
			var cm := ArrayMesh.new()
			cm.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, data.coarse[li])
			levels.append([cm, TERRAIN_LOD[li], TERRAIN_LOD[li + 1]])
		for level in levels:
			var mi := MeshInstance3D.new()
			mi.mesh = level[0]
			mi.material_override = terrain_material
			mi.set_meta("strip", "terrain")
			mi.visibility_range_begin = level[1]
			mi.visibility_range_end = level[2]
			parent.add_child(mi)
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(data.faces)
		var cs := CollisionShape3D.new()
		cs.shape = shape
		var body := StaticBody3D.new()
		body.set_meta("surface", Surfaces.GRASS)
		body.add_child(cs)
		ground.add_child(body)
		if progress.is_valid():
			progress.call("Preparing terrain", ci + 1, list.size())
		# Keep sorted chunk attachment/RNG order; yield only between whole chunks.
		if yield_frames and Time.get_ticks_usec() - slice_start >= 6000:
			await parent.get_tree().process_frame
			slice_start = Time.get_ticks_usec()
	if progress.is_valid():
		progress.call("Preparing road and crossings", 0, 0)
	if yield_frames:
		await parent.get_tree().process_frame
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
	_trunks(parent)
	_barriers(parent)
	_streams(parent)
	return list.size()


## Collision is independent of camera LOD/streaming. Small static blocks keep
## the broadphase from testing a car against the entire stage's tree shapes.
func _trunks(parent: Node3D) -> void:
	var trees := Node3D.new()
	trees.name = "Trunks"
	parent.add_child(trees)
	# A shared twelve-sided trunk supports the visual nonuniform height scale
	# without depending on a primitive cylinder's scale restrictions.
	var trunk := ConvexPolygonShape3D.new()
	var points := PackedVector3Array()
	for y in [-0.5, 5.5]:
		for i in 12:
			var angle := TAU * float(i) / 12.0
			points.append(Vector3(cos(angle) * 0.22, y, sin(angle) * 0.22))
	trunk.points = points
	var blocks := {}
	for xf in tree_colliders:
		var p := xf.origin
		var key := Vector2i(floori(p.x / TRUNK_BLOCK), floori(p.z / TRUNK_BLOCK))
		if not blocks.has(key):
			var b := StaticBody3D.new()
			b.collision_layer = 1
			b.collision_mask = 1
			b.set_meta("surface", Surfaces.DIRT)
			trees.add_child(b)
			blocks[key] = b
		var cs := CollisionShape3D.new()
		cs.shape = trunk
		cs.transform = xf
		blocks[key].add_child(cs)


## Water ribbons for the streams, and a timber bridge where the road crosses
## one on a bridge.
func _streams(parent: Node3D) -> void:
	var water := ShaderMaterial.new()
	water.shader = preload("res://src/shaders/water.gdshader")
	for r in stage.rivers:
		var pts: PackedVector2Array = r.pts
		var k := 0
		while k < pts.size():
			if r.wet[k] == 0:
				k += 1
				continue
			var e := k
			while e < pts.size() - 1 and r.wet[e + 1] == 1:
				e += 1
			if e > k:
				var mi := MeshInstance3D.new()
				mi.mesh = _water_mesh(r, k, e)
				mi.material_override = water
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				mi.visibility_range_end = 700.0
				parent.add_child(mi)
			k = e + 1
		if not r.ford:
			_bridge(parent, r)


func _water_mesh(r: Dictionary, from: int, to: int) -> ArrayMesh:
	var pts: PackedVector2Array = r.pts
	var w: float = r.half + 1.8
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	var along := 0.0
	var last := [Vector2.INF, Vector2.INF]
	for k in range(from, to + 1):
		# Direction over a few points either side: smoother bends.
		var a := pts[maxi(k - 3, 0)]
		var b := pts[mini(k + 3, pts.size() - 1)]
		var f := (b - a).normalized()
		var side := Vector2(-f.y, f.x)
		var y: float = r.levels[k]
		if k > from:
			along += pts[k].distance_to(pts[k - 1])
		for si in 2:
			var sgn := -1.0 if si == 0 else 1.0
			var q: Vector2 = pts[k] + side * w * sgn
			# On the inside of a tight bend the edge would run backwards and
			# fold the ribbon over itself: two layers of water showing as
			# overlapping squares. Keep every edge moving downstream.
			if last[si] != Vector2.INF and (q - last[si]).dot(f) < 0.05:
				q += f * (0.05 - (q - last[si]).dot(f))
			last[si] = q
			verts.append(Vector3(q.x, y, q.y))
			uvs.append(Vector2(sgn * 0.5 + 0.5, along))
		if k < to:
			var v := (k - from) * 2
			idx.append_array([v, v + 2, v + 1, v + 1, v + 2, v + 3])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	var normals := PackedVector3Array()
	normals.resize(verts.size())
	normals.fill(Vector3.UP)
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## A timber bridge: a deck under the road ribbon (which stays the driving
## surface), beams, posts and a rail on each side.
func _bridge(parent: Node3D, r: Dictionary) -> void:
	var c: int = r.cross
	var wood := StandardMaterial3D.new()
	wood.albedo_texture = load("res://assets/textures/forest_ground_04_albedo.jpg")
	wood.albedo_color = Color(0.55, 0.42, 0.3)
	wood.uv1_triplanar = true
	wood.uv1_world_triplanar = true
	wood.uv1_scale = Vector3(0.3, 2.0, 0.3)
	wood.roughness = 0.85
	wood.cull_mode = BaseMaterial3D.CULL_DISABLED
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(wood)
	var span := int(ceil((r.half + 6.0) / Stage.STEP))
	var body := StaticBody3D.new()
	body.name = "Bridge"
	body.set_meta("surface", Surfaces.DIRT)
	parent.add_child(body)
	for k in range(c - span, c + span + 1):
		var p := stage.points[k]
		var f := stage.dirs[k]
		var right := Vector3(-f.z, 0.0, f.x)
		var w := stage.widths[k] + 0.5
		# Deck slab under the ribbon.
		_box(st, p + Vector3.UP * -0.25, right * w, Vector3.UP * 0.2, f * Stage.STEP * 0.5)
		for sgn in [-1.0, 1.0]:
			var edge: Vector3 = p + right * sgn * (w + 0.1)
			if k % 2 == 0:
				_box(st, edge + Vector3.UP * 0.45, right * 0.07, Vector3.UP * 0.55, f * 0.07)
			# Top rail and a mid rail.
			_box(st, edge + Vector3.UP * 0.95, right * 0.06, Vector3.UP * 0.05, f * Stage.STEP * 0.52)
			_box(st, edge + Vector3.UP * 0.5, right * 0.04, Vector3.UP * 0.04, f * Stage.STEP * 0.52)
			var box := BoxShape3D.new()
			box.size = Vector3(0.25, 1.1, Stage.STEP + 0.2)
			var cs := CollisionShape3D.new()
			cs.shape = box
			cs.transform = Transform3D(Basis.looking_at(f, Vector3.UP), edge + Vector3.UP * 0.55)
			body.add_child(cs)
	# Piers down to the stream bed.
	for k in [c - span + 1, c + span - 1]:
		var p := stage.points[k]
		var f := stage.dirs[k]
		var right := Vector3(-f.z, 0.0, f.x)
		_box(st, p + Vector3.UP * -2.5, right * (stage.widths[k] + 0.4), Vector3.UP * 2.2, f * 0.3)
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	parent.add_child(mi)


## Along the drop of every ledge: a dry-stone wall or an Armco rail, with
## colliders, so a mistake costs time rather than the stage.
func _barriers(parent: Node3D) -> void:
	var body := Node3D.new()
	body.name = "Barriers"
	parent.add_child(body)
	var stone := StandardMaterial3D.new()
	stone.albedo_texture = load("res://assets/textures/stone_wall_04_albedo.jpg")
	stone.normal_enabled = true
	stone.normal_texture = load("res://assets/textures/stone_wall_04_normal.jpg")
	stone.uv1_triplanar = true
	stone.uv1_world_triplanar = true
	stone.uv1_scale = Vector3(0.6, 0.6, 0.6)
	stone.albedo_color = Color(0.78, 0.76, 0.72)
	stone.roughness = 0.9
	var steel := StandardMaterial3D.new()
	steel.albedo_color = Color(0.62, 0.64, 0.66)
	steel.metallic = 0.7
	steel.roughness = 0.42
	stone.cull_mode = BaseMaterial3D.CULL_DISABLED
	steel.cull_mode = BaseMaterial3D.CULL_DISABLED
	var n := stage.points.size()
	var i := 0
	while i < n:
		if absf(stage.ledges[i]) < 0.35:
			i += 1
			continue
		var j := i
		while j < n - 1 and absf(stage.ledges[j + 1]) >= 0.35:
			j += 1
		var side := -signf(stage.ledges[i]) # the drop side
		var rail := hash(i) % 2 == 0
		var line := PackedVector3Array()
		for k in range(i, j + 1):
			var right := Vector3(-stage.dirs[k].z, 0.0, stage.dirs[k].x)
			line.append(stage.points[k] + right * side * (stage.widths[k] + 1.3))
		var mi := MeshInstance3D.new()
		mi.mesh = _rail_mesh(line, steel) if rail else _wall_mesh(line, stone)
		mi.visibility_range_end = 500.0
		parent.add_child(mi)
		var run := StaticBody3D.new() # one body per wall, see build()
		run.set_meta("surface", Surfaces.DIRT)
		body.add_child(run)
		for k in line.size() - 1:
			var a := line[k]
			var b := line[k + 1]
			var box := BoxShape3D.new()
			box.size = Vector3(0.4, 1.0, a.distance_to(b) + 0.3)
			var cs := CollisionShape3D.new()
			cs.shape = box
			cs.transform = Transform3D(Basis.looking_at(b - a, Vector3.UP), (a + b) * 0.5 + Vector3.UP * 0.35)
			run.add_child(cs)
		i = j + 1


## A low dry-stone wall: a tapered profile swept along the line.
func _wall_mesh(line: PackedVector3Array, mat: Material) -> ArrayMesh:
	var profile := [Vector2(-0.28, -0.5), Vector2(-0.24, 0.62), Vector2(-0.12, 0.74), Vector2(0.12, 0.74), Vector2(0.24, 0.62), Vector2(0.28, -0.5)]
	return _sweep(line, profile, mat)


## An Armco rail: a W-beam at bumper height on posts every two metres.
func _rail_mesh(line: PackedVector3Array, mat: Material) -> ArrayMesh:
	var beam := [Vector2(0.0, 0.42), Vector2(0.07, 0.48), Vector2(0.0, 0.55), Vector2(0.07, 0.62), Vector2(0.0, 0.68), Vector2(-0.03, 0.68), Vector2(-0.03, 0.42)]
	var mesh := _sweep(line, beam, mat)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(mat)
	for k in line.size():
		var right := _side_of(line, k)
		var c := line[k] - right * 0.08
		var f := (line[mini(k + 1, line.size() - 1)] - line[maxi(k - 1, 0)]).normalized()
		_box(st, c + Vector3.UP * 0.1, right * 0.05, Vector3.UP * 0.6, f * 0.04)
	st.generate_normals()
	st.commit(mesh)
	return mesh


func _side_of(line: PackedVector3Array, k: int) -> Vector3:
	var f := line[mini(k + 1, line.size() - 1)] - line[maxi(k - 1, 0)]
	return Vector3(-f.z, 0.0, f.x).normalized()


func _sweep(line: PackedVector3Array, profile: Array, mat: Material) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(mat)
	var rings: Array[PackedVector3Array] = []
	for k in line.size():
		var right := _side_of(line, k)
		var ring := PackedVector3Array()
		for q in profile:
			ring.append(line[k] + right * q.x + Vector3.UP * q.y)
		rings.append(ring)
	for k in rings.size() - 1:
		for q in profile.size() - 1:
			var a := rings[k][q]
			var b := rings[k][q + 1]
			var c := rings[k + 1][q]
			var d := rings[k + 1][q + 1]
			for v in [a, c, b, b, c, d]:
				st.add_vertex(v)
	st.generate_normals()
	return st.commit()


## A box from its centre and three half-axes.
func _box(st: SurfaceTool, c: Vector3, x: Vector3, y: Vector3, z: Vector3) -> void:
	var p := []
	for k in 8:
		p.append(c + x * (1 if k & 1 else -1) + y * (1 if k & 2 else -1) + z * (1 if k & 4 else -1))
	for f in [[0, 2, 1, 3], [4, 5, 6, 7], [0, 1, 4, 5], [2, 6, 3, 7], [0, 4, 2, 6], [1, 3, 5, 7]]:
		for v in [f[0], f[1], f[2], f[2], f[1], f[3]]:
			st.add_vertex(p[v])
