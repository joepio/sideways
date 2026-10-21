class_name Stage
extends Node3D
## A Finnish gravel stage: one narrow road through rolling pine forest, with
## fast crests, ditches on both sides and the odd tight junction corner.
##
## The layout comes from the global RNG (seeded by the round), so the same
## seed gives the same stage. The road is a centre line sampled every STEP
## metres; the terrain is noise, pulled down to the road near it and cut into
## ditches beside it.

const STEP := 2.0
const CELL := 32.0
## How far from the centre line the road still shapes the ground.
const REACH := 70.0
const CHUNK := 64.0
const GRID := 2.0 ## terrain vertex spacing
const CORRIDOR := 230.0 ## terrain this far from the road

var points := PackedVector3Array() ## centre line
var dirs := PackedVector3Array() ## unit tangent (horizontal)
var widths := PackedFloat32Array() ## half width
var curvature := PackedFloat32Array() ## signed 1/m, + is left
var length := 0.0
## Where the finish line is: the road runs on past it so a car at full
## speed has room to stop (it used to end in the trees 8 m after the line).
var finish := 0.0
const RUNOUT := 140.0
var ledges := PackedFloat32Array() ## per point: 0, or the strength (signed: + has the rock wall on the right) of a stretch cut into a hillside
var ledge_wall := PackedFloat32Array() ## per point: metres the rock rises on the wall side
var ledge_drop := PackedFloat32Array() ## per point: metres the ground falls away on the other side
## Streams crossing the road: {"pts": PackedVector2Array, "levels": PackedFloat32Array
## (water surface per point), "wet": PackedByteArray (1 where there is water),
## "half": half width, "depth": metres, "cross": road point index, "ford": bool}.
var rivers: Array[Dictionary] = []
const RIVER_STEP := 4.0
var _river_hash := {} ## Vector2i cell -> Array of Vector2i(river, point)
var _river_candidates := {} ## query cell -> ordered points in its 3x3 neighbourhood
var notes: Array[Dictionary] = [] ## pace notes: {"at": m, "kind": "left"/"right"/"crest", "grade": 1..6}

var _hash := {} ## Vector2i cell -> PackedInt32Array of point indices
var _locate_candidates := {} ## query cell -> ordered indices in its 3x3 neighbourhood
var _noise := FastNoiseLite.new()
var _detail := FastNoiseLite.new()


func generate(target_length: float) -> void:
	_noise.seed = randi()
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.frequency = 1.0 / 420.0
	_noise.fractal_octaves = 3
	_detail.seed = randi()
	_detail.frequency = 1.0 / 70.0
	_detail.fractal_octaves = 2
	_layout(target_length)
	_profile()
	_ledges()
	_rivers()
	_index()
	_pace_notes()


## The road as straights and corners, steered back towards the general
## direction so it never loops onto itself.
func _layout(target_length: float) -> void:
	var tries := 0
	while true:
		tries += 1
		var pts: Array[Vector2] = [Vector2.ZERO]
		var heading := 0.0
		var k := 0.0
		var ok := true
		var plan: Array[Dictionary] = [{"len": 120.0, "k": 0.0}]
		var total := 0.0
		while total < target_length:
			var last: Dictionary = plan[-1]
			if last.k == 0.0:
				# A corner. Radius by pace-note grade; 6 is flat out, 1 is a hairpin.
				var grade := _pick_grade()
				var radius: float = [14.0, 24.0, 38.0, 60.0, 95.0, 150.0, 240.0][grade]
				var angle: float = deg_to_rad(randf_range(25.0, 95.0) if grade > 1 else randf_range(80.0, 170.0))
				var dir := 1.0 if randf() < 0.5 else -1.0
				# Lean back towards the main direction.
				if absf(heading) > deg_to_rad(60.0):
					dir = -signf(heading)
				plan.append({"len": radius * angle, "k": dir / radius})
			else:
				plan.append({"len": randf_range(30.0, 260.0) if randf() < 0.7 else randf_range(15.0, 50.0), "k": 0.0})
			total += plan[-1].len
		# Walk the plan with curvature eased over 18 m, so corners have entries.
		var s := 0.0
		var p := Vector2.ZERO
		var seg := 0
		var into := 0.0
		while seg < plan.size():
			var want: float = plan[seg].k
			k = move_toward(k, want, STEP / 18.0 * maxf(absf(want), absf(k)) + 0.0005)
			heading += k * STEP
			p += Vector2(sin(heading), -cos(heading)) * STEP
			pts.append(p)
			s += STEP
			into += STEP
			if into >= plan[seg].len:
				into = 0.0
				seg += 1
		# Self-crossing check: far-apart parts of the road keep 70 m away.
		var grid := {}
		for i in pts.size():
			var c := Vector2i(floori(pts[i].x / 70.0), floori(pts[i].y / 70.0))
			for dx in [-1, 0, 1]:
				for dy in [-1, 0, 1]:
					for j in grid.get(c + Vector2i(dx, dy), []):
						if i - j > 60 and pts[i].distance_to(pts[j]) < 70.0:
							ok = false
			if not ok:
				break
			if not grid.has(c):
				grid[c] = []
			grid[c].append(i)
		if ok or tries > 40:
			points.clear()
			for q in pts:
				points.append(Vector3(q.x, 0.0, q.y))
			return


func _pick_grade() -> int:
	var r := randf()
	if r < 0.04:
		return 0
	if r < 0.12:
		return 1
	if r < 0.27:
		return 2
	if r < 0.47:
		return 3
	if r < 0.70:
		return 4
	if r < 0.88:
		return 5
	return 6


## Height along the road: the terrain, smoothed, grade limited, plus the
## crests Finnish stages are famous for.
func _profile() -> void:
	var n := points.size()
	var raw := PackedFloat32Array()
	raw.resize(n)
	for i in n:
		raw[i] = _ground(points[i].x, points[i].z)
	# Gaussian-ish smoothing over about 90 m.
	var smooth := raw.duplicate()
	for _pass in 3:
		var out := smooth.duplicate()
		var r := 15
		for i in n:
			var acc := 0.0
			var cnt := 0
			for j in range(maxi(0, i - r), mini(n, i + r + 1)):
				acc += smooth[j]
				cnt += 1
			out[i] = acc / cnt
		smooth = out
	# Grade limit, 11 %.
	var max_d := 0.11 * STEP
	for i in range(1, n):
		smooth[i] = clampf(smooth[i], smooth[i - 1] - max_d, smooth[i - 1] + max_d)
	for i in range(n - 2, -1, -1):
		smooth[i] = clampf(smooth[i], smooth[i + 1] - max_d, smooth[i + 1] + max_d)
	# Crests on the straights: short sharp rises that unload the car.
	dirs.resize(n)
	curvature.resize(n)
	widths.resize(n)
	for i in n:
		var a := points[maxi(i - 1, 0)]
		var b := points[mini(i + 1, n - 1)]
		dirs[i] = (b - a).normalized()
	for i in n:
		var a := dirs[maxi(i - 3, 0)]
		var b := dirs[mini(i + 3, n - 1)]
		var turn := atan2(a.cross(b).y, a.dot(b))
		curvature[i] = turn / (STEP * float(mini(i + 3, n - 1) - maxi(i - 3, 0)))
	var i := 40
	while i < n - 40:
		var straight := true
		for j in range(i - 15, i + 15):
			if absf(curvature[j]) > 1.0 / 400.0:
				straight = false
				break
		if straight and randf() < 0.35:
			var height := randf_range(0.6, 1.6)
			var half := randf_range(5.0, 9.0) # in points
			for j in range(i - 20, i + 20):
				var x := (j - i) / half
				smooth[j] += height * exp(-x * x)
			i += 60
		else:
			i += 5
	for j in n:
		points[j].y = smooth[j]
		widths[j] = 3.4 + 0.5 * _detail.get_noise_1d(j * 0.7)
	length = (n - 1) * STEP
	finish = length - RUNOUT


## Ledges: now and then the road is cut into a steep hillside, with a rock
## wall on the high side and a drop on the other, as on the Monte Carlo or
## Finnish lakeside stages. The high side is wherever the land rises.
func _ledges() -> void:
	var n := points.size()
	ledges.resize(n)
	ledges.fill(0.0)
	ledge_wall.resize(n)
	ledge_drop.resize(n)
	var i := 90
	while i < n - 80:
		if randf() > 0.007:
			i += 1
			continue
		var len := randi_range(60, 150)
		var end := mini(i + len, n - 60)
		var mid := (i + end) / 2
		var right := Vector3(-dirs[mid].z, 0.0, dirs[mid].x)
		var p := points[mid]
		var rise := _ground(p.x + right.x * 40.0, p.z + right.z * 40.0) - _ground(p.x - right.x * 40.0, p.z - right.z * 40.0)
		var side := 1.0 if rise >= 0.0 else -1.0
		var wall := randf_range(9.0, 22.0)
		var drop := randf_range(14.0, 34.0)
		for j in range(i, end + 1):
			# Eased in and out over 30 m.
			var ease := minf(smoothstep(0.0, 15.0, j - i), smoothstep(0.0, 15.0, end - j))
			ledges[j] = side * ease
			ledge_wall[j] = wall
			ledge_drop[j] = drop
		i = end + 100


## One or two streams per stage. Each meanders across the road; it runs
## level for a stretch either side of the crossing and then follows the land,
## only ever downhill in the direction it flows, cutting a gully where the
## land is higher than the water and drying up where it is lower. Fords dip
## the road into the water; bridges carry it over.
func _rivers() -> void:
	rivers.clear()
	_river_hash.clear()
	_river_candidates.clear()
	var n := points.size()
	var count := 1 if length < 2500.0 else 2
	var tries := 0
	while rivers.size() < count and tries < 40:
		tries += 1
		var c := randi_range(150, n - 150)
		var clear := true
		for j in range(c - 40, c + 40):
			if ledges[j] != 0.0 or (absf(j - c) < 20 and absf(curvature[j]) > 1.0 / 90.0):
				clear = false
				break
		for r in rivers:
			if absf(r.cross - c) < 250:
				clear = false
		if not clear:
			continue
		var ford := randf() < 0.5
		var half := randf_range(2.5, 4.5)
		var depth := randf_range(0.7, 1.3)
		var right := Vector2(-dirs[c].z, dirs[c].x)
		# The water sits a little below the land at the crossing.
		var land := INF
		for k in range(-4, 5):
			var q := Vector2(points[c + k].x, points[c + k].z)
			for sgn in [-1.0, 1.0]:
				var b: Vector2 = q + right * sgn * (widths[c] + 4.0)
				land = minf(land, _ground(b.x, b.y))
		var road_h := points[c].y
		var level := minf(land - 0.3, road_h + 0.22) if ford else minf(land - 0.5, road_h - 2.0)
		if ford:
			# The road dips into the stream, gently.
			var dip := road_h - (level - 0.22)
			if dip > 3.0:
				ford = false
				level = minf(land - 0.5, road_h - 2.0)
			else:
				var sigma := 6.0 + dip * 4.0
				for j in range(c - int(sigma * 2.5), c + int(sigma * 2.5) + 1):
					var x := (j - c) / sigma
					points[j].y -= dip * exp(-x * x)
		var heading := right.angle() + randf_range(-0.4, 0.4)
		# Walk out both ways from the crossing.
		var half_len := 75
		var up_pts: Array[Vector2] = []
		var down_pts: Array[Vector2] = []
		for way in [1.0, -1.0]:
			var p := Vector2(points[c].x, points[c].z)
			var hd: float = heading if way > 0.0 else heading + PI
			for k in half_len:
				hd += (_detail.get_noise_1d(k * 3.1 + way * 50.0 + c) ) * 0.35
				p += Vector2(cos(hd), sin(hd)) * RIVER_STEP
				(down_pts if way > 0.0 else up_pts).append(p)
		var pts := PackedVector2Array()
		for k in range(up_pts.size() - 1, -1, -1):
			pts.append(up_pts[k])
		pts.append(Vector2(points[c].x, points[c].z))
		for q in down_pts:
			pts.append(q)
		var mid := up_pts.size()
		var levels := PackedFloat32Array()
		levels.resize(pts.size())
		levels[mid] = level
		var flat := 18 # points level either side
		for k in range(mid - 1, -1, -1):
			var t := _ground(pts[k].x, pts[k].y) - 0.6
			levels[k] = levels[k + 1] if mid - k < flat else maxf(levels[k + 1], minf(t, levels[k + 1] + 0.12 * RIVER_STEP))
		for k in range(mid + 1, pts.size()):
			var t := _ground(pts[k].x, pts[k].y) - 0.6
			levels[k] = levels[k - 1] if k - mid < flat else minf(levels[k - 1], maxf(t, levels[k - 1] - 0.12 * RIVER_STEP))
		var wet := PackedByteArray()
		wet.resize(pts.size())
		for k in pts.size():
			var g := _ground(pts[k].x, pts[k].y)
			# Water where the land holds it, gullies no deeper than 9 m.
			wet[k] = 1 if g > levels[k] - 0.3 and g < levels[k] + 9.0 else 0
		wet[mid] = 1
		var r := {"pts": pts, "levels": levels, "wet": wet, "half": half, "depth": depth, "cross": c, "ford": ford}
		rivers.append(r)
	_index_rivers()


## Rebuild after changing river points. Queries only read these tables,
## including terrain-building workers; nothing is cached lazily at runtime.
func _index_rivers() -> void:
	_river_hash.clear()
	_river_candidates.clear()
	for ri in rivers.size():
		var pts: PackedVector2Array = rivers[ri].pts
		for k in pts.size():
			var cell := Vector2i(floori(pts[k].x / CELL), floori(pts[k].y / CELL))
			if not _river_hash.has(cell):
				_river_hash[cell] = []
			_river_hash[cell].append(Vector2i(ri, k))
	for cell in _query_cells(_river_hash):
		var candidates: Array[Vector2i] = []
		# Keep the original query order: equal distances choose the first
		# point visited, which need not be the lowest river/point index.
		for dx in [-1, 0, 1]:
			for dy in [-1, 0, 1]:
				var key: Vector2i = cell + Vector2i(dx, dy)
				if _river_hash.has(key):
					candidates.append_array(_river_hash[key])
		_river_candidates[cell] = candidates


## The nearest stream point to (x, z) within `reach`: {river, point, d, level}
## or empty.
func _river_near(x: float, z: float, reach: float) -> Dictionary:
	if rivers.is_empty():
		return {}
	var c := Vector2i(floori(x / CELL), floori(z / CELL))
	var best := {}
	var best_d := reach * reach
	var q := Vector2(x, z)
	for id in _river_candidates.get(c, []):
		var r: Dictionary = rivers[id.x]
		var d := q.distance_squared_to(r.pts[id.y])
		if d < best_d:
			best_d = d
			best = {"river": id.x, "point": id.y}
	if best.is_empty():
		return best
	# Refine against the neighbouring segments.
	var r: Dictionary = rivers[best.river]
	var pts: PackedVector2Array = r.pts
	var k: int = best.point
	var bd := INF
	var level := 0.0
	for s in [k - 1, k]:
		if s < 0 or s + 1 >= pts.size():
			continue
		var a := pts[s]
		var b := pts[s + 1]
		var t := clampf((q - a).dot(b - a) / (b - a).length_squared(), 0.0, 1.0)
		var d := q.distance_to(a.lerp(b, t))
		if d < bd:
			bd = d
			level = lerpf(r.levels[s], r.levels[s + 1], t)
	best.d = bd
	best.level = level
	return best


## Water surface height at (x, z), or -INF where there is no water.
func water_level(x: float, z: float) -> float:
	var near := _river_near(x, z, 12.0)
	if near.is_empty():
		return -INF
	var r: Dictionary = rivers[near.river]
	if r.wet[near.point] == 0 or near.d > r.half + 0.5:
		return -INF
	return near.level


func _index() -> void:
	_hash.clear()
	_locate_candidates.clear()
	for i in points.size():
		var c := Vector2i(floori(points[i].x / CELL), floori(points[i].z / CELL))
		if not _hash.has(c):
			_hash[c] = PackedInt32Array()
		_hash[c].append(i)
	for cell in _query_cells(_hash):
		var candidates := PackedInt32Array()
		for dx in [-1, 0, 1]:
			for dy in [-1, 0, 1]:
				var key: Vector2i = cell + Vector2i(dx, dy)
				if _hash.has(key):
					candidates.append_array(_hash[key])
		_locate_candidates[cell] = candidates


## Only cells adjacent to an occupied hash cell can have 3x3 candidates.
## Every source point appears in exactly nine lists; order within each list
## is set by the callers, not by this dictionary's key order.
static func _query_cells(index: Dictionary) -> Array:
	var cells := {}
	for cell in index:
		for dx in [-1, 0, 1]:
			for dy in [-1, 0, 1]:
				cells[cell + Vector2i(dx, dy)] = true
	return cells.keys()


## Nearest point on the centre line to `p` (horizontal), with how far along
## the road it is and the signed offset (+ is right of the road).
func locate(p: Vector3, hint := -1) -> Dictionary:
	var best := -1
	var best_d := INF
	if hint >= 0:
		# Search near the last known spot first: cheap and avoids snapping
		# to another part of the road on a near-crossing.
		for j in range(maxi(0, hint - 30), mini(points.size(), hint + 30)):
			var d := Vector2(points[j].x - p.x, points[j].z - p.z).length_squared()
			if d < best_d:
				best_d = d
				best = j
		if best_d < 30.0 * 30.0:
			return _result(p, best)
	var c := Vector2i(floori(p.x / CELL), floori(p.z / CELL))
	for j in _locate_candidates.get(c, PackedInt32Array()):
		var d := Vector2(points[j].x - p.x, points[j].z - p.z).length_squared()
		if d < best_d:
			best_d = d
			best = j
	if best < 0:
		return {"index": -1, "along": 0.0, "offset": INF, "height": 0.0}
	return _result(p, best)


func _result(p: Vector3, i: int) -> Dictionary:
	# Project onto the segment towards the neighbour for a smooth result.
	var d := dirs[i]
	var rel := p - points[i]
	var t := clampf(rel.x * d.x + rel.z * d.z, -STEP, STEP)
	var right := Vector3(-d.z, 0.0, d.x)
	var offset := rel.x * right.x + rel.z * right.z
	var j := clampi(i + (1 if t > 0.0 else -1), 0, points.size() - 1)
	var h := lerpf(points[i].y, points[j].y, absf(t) / STEP)
	return {"index": i, "along": i * STEP + t, "offset": offset, "height": h, "right": right}


func point_at(along: float) -> Vector3:
	var f := clampf(along / STEP, 0.0, points.size() - 1.001)
	var i := int(f)
	return points[i].lerp(points[i + 1], f - i)


func dir_at(along: float) -> Vector3:
	var i := clampi(int(along / STEP), 0, dirs.size() - 1)
	return dirs[i]


func width_at(along: float) -> float:
	return widths[clampi(int(along / STEP), 0, widths.size() - 1)]


func curvature_at(along: float) -> float:
	return curvature[clampi(int(along / STEP), 0, curvature.size() - 1)]


## Road surface by how far from the centre: the driven line is firm gravel,
## the outer edge loose stones, then the verge.
func surface_at(p: Vector3) -> int:
	return surface_near(p, -1).x


## The surface at `p` and the road point it was found at (pass that back as
## `hint` next time: the search then stays local and cheap).
func surface_near(p: Vector3, hint: int) -> Vector2i:
	var r := locate(p, hint)
	return Vector2i(_surface_from(r), r.index)


func _surface_from(r: Dictionary) -> int:
	var off := absf(r.offset)
	var w := width_at(r.along)
	if off < w - 0.9:
		return Surfaces.GRAVEL
	if off < w + 0.6:
		return Surfaces.LOOSE
	return Surfaces.GRASS


## Natural ground without the road.
func _ground(x: float, z: float) -> float:
	return _noise.get_noise_2d(x, z) * 34.0 + _detail.get_noise_2d(x, z) * 3.0


## A stream's bed and banks cut into `h`: flat bottom, steep sides, then a
## 1 in 2 bank back up to the land.
func _carve(x: float, z: float, h: float) -> float:
	var near := _river_near(x, z, 40.0)
	if near.is_empty():
		return h
	var r: Dictionary = rivers[near.river]
	var d: float = near.d
	var half: float = r.half
	var bed: float = near.level - r.depth * (1.0 - smoothstep(half * 0.45, half, d)) + 0.25 * smoothstep(half * 0.8, half, d)
	bed += maxf(d - half, 0.0) * 0.5
	return minf(h, bed)


## Ground height with the road cut in: flat road, a shoulder, a ditch, then
## the embankment or cutting back up to the natural ground. `near` is the
## nearest centre-line index (or -1 when the road is far away).
func height_near(x: float, z: float, near: int) -> float:
	return _carve(x, z, _height_near(x, z, near))


func _height_near(x: float, z: float, near: int) -> float:
	var natural := _ground(x, z)
	if near < 0:
		return natural
	var r := _result(Vector3(x, 0.0, z), near)
	var off := absf(r.offset)
	if off > REACH:
		return natural
	var w := widths[near]
	var road_h: float = r.height - 0.06 * clampf(off / w, 0.0, 1.0) # crown
	if off < w + 0.8:
		return road_h - 0.08
	# Ditch 1.2 to 3.2 m outside the edge, about half a metre deep.
	var dx_ := off - (w + 2.2)
	var ditch := -0.55 * exp(-dx_ * dx_ / 0.9)
	# Banks back up to the natural ground no steeper than about 1 in 3, so a
	# big height difference gets a long, gentle embankment instead of a wall.
	var reach := clampf(absf(natural - road_h) / 0.32, 12.0, 60.0)
	var blend := smoothstep(w + 3.0, w + 3.0 + reach, off)
	var normal := lerpf(road_h, natural, blend) + ditch * (1.0 - blend * 0.6)
	var ledge := ledges[near]
	if ledge == 0.0:
		return normal
	var back := smoothstep(w + 14.0, REACH - 5.0, off)
	if signf(r.offset) == signf(ledge):
		# The rock wall: up within a few metres, broken by noise, then a
		# shelf that blends back into the land.
		var face := smoothstep(w + 2.4, w + 7.0, off)
		var rock := road_h + ledge_wall[near] * face + _detail.get_noise_2d(x * 3.0, z * 3.0) * 1.4 * face * (1.0 - face)
		rock = lerpf(rock, natural, back)
		return lerpf(normal, maxf(normal, rock), absf(ledge))
	# The drop: a flat shoulder for the wall or rail, then steeply down.
	var fall := road_h - 0.1 - ledge_drop[near] * smoothstep(w + 1.9, w + 11.0, off)
	fall = lerpf(fall, natural, back)
	return lerpf(normal, minf(normal, fall), absf(ledge))


func height(x: float, z: float) -> float:
	return height_near(x, z, nearest_index(x, z))


func nearest_index(x: float, z: float) -> int:
	var c := Vector2i(floori(x / CELL), floori(z / CELL))
	var best := -1
	var best_d := REACH * REACH
	for dx in [-3, -2, -1, 0, 1, 2, 3]:
		for dy in [-3, -2, -1, 0, 1, 2, 3]:
			for j in _hash.get(c + Vector2i(dx, dy), PackedInt32Array()):
				var d := Vector2(points[j].x - x, points[j].z - z).length_squared()
				if d < best_d:
					best_d = d
					best = j
	return best


## Road point indices that may be nearest to anything in the square, as
## runs of consecutive indices (one run per pass of the road).
func runs_near(x0: float, z0: float, size: float, margin: float) -> Array[PackedInt32Array]:
	var idx := PackedInt32Array()
	var c0 := Vector2i(floori((x0 - margin) / CELL), floori((z0 - margin) / CELL))
	var c1 := Vector2i(floori((x0 + size + margin) / CELL), floori((z0 + size + margin) / CELL))
	for cx in range(c0.x, c1.x + 1):
		for cy in range(c0.y, c1.y + 1):
			for j in _hash.get(Vector2i(cx, cy), PackedInt32Array()):
				var p := points[j]
				if p.x > x0 - margin and p.x < x0 + size + margin and p.z > z0 - margin and p.z < z0 + size + margin:
					idx.append(j)
	idx.sort()
	var runs: Array[PackedInt32Array] = []
	for j in idx:
		if runs.is_empty() or j - runs[-1][-1] > 3:
			runs.append(PackedInt32Array())
		runs[-1].append(j)
	return runs


func _pace_notes() -> void:
	notes.clear()
	var i := 0
	var n := curvature.size()
	while i < n:
		var k := curvature[i]
		if absf(k) > 1.0 / 300.0:
			# Walk the corner, keep its tightest point.
			var j := i
			var peak := 0.0
			var turn := 0.0
			while j < n and absf(curvature[j]) > 1.0 / 400.0 and signf(curvature[j]) == signf(k):
				peak = maxf(peak, absf(curvature[j]))
				turn += absf(curvature[j]) * STEP
				j += 1
			if turn > deg_to_rad(12.0):
				var radius := 1.0 / peak
				var grade := 6
				for g in [[20.0, 1], [32.0, 2], [50.0, 3], [80.0, 4], [125.0, 5]]:
					if radius < g[0]:
						grade = g[1]
						break
				if radius < 17.0:
					grade = 0 # hairpin
				notes.append({"at": i * STEP, "kind": "left" if k > 0.0 else "right", "grade": grade, "end": j * STEP})
			i = j + 1
		else:
			i += 1
	# Crests: a sharp drop of the slope.
	for j in range(10, points.size() - 10, 4):
		var before := points[j].y - points[j - 6].y
		var after := points[j + 6].y - points[j].y
		if before - after > 0.9:
			if notes.is_empty() or absf(notes[-1].at - j * STEP) > 40.0:
				notes.append({"at": j * STEP, "kind": "crest", "grade": 0, "end": j * STEP})
	notes.sort_custom(func(a, b): return a.at < b.at)
