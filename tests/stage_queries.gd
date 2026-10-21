extends SceneTree
## Compare cached candidates with the original cell loops, including the
## intentional hint preference and first-visited tie ordering.

var _failed := false
var _checks := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var stage := Stage.new()
	for stage_seed in [1, 7, 17, 99, 4242, 20261021]:
		seed(stage_seed)
		stage.generate(4000.0 if stage_seed == 99 or stage_seed == 4242 else 2140.0)
		_check_candidates(stage)
		_check_generated(stage)
		print("stage queries: seed %d, %d road points, %d streams" % [stage_seed, stage.points.size(), stage.rivers.size()])
	_check_fixtures(stage)
	stage.free()
	if not _failed:
		print("stage queries: %d exact-result checks passed" % _checks)
	quit(1 if _failed else 0)


func _check_generated(stage: Stage) -> void:
	for i in range(0, stage.points.size(), 47):
		var p := stage.points[i]
		var right := Vector3(-stage.dirs[i].z, 0.0, stage.dirs[i].x)
		var w := stage.widths[i]
		var hints := PackedInt32Array([-1, -2, 0, i, maxi(0, i - 41), stage.points.size() - 1, stage.points.size() + 100])
		for off in [-70.0, -32.0, -w - 0.6001, -w - 0.6, -w + 0.9, 0.0, w - 0.9001, w - 0.9, w + 0.6, w + 0.6001, 32.0, 70.0]:
			_check_road(stage, p + right * off, hints)
		var x_edge := floorf(p.x / Stage.CELL) * Stage.CELL
		var z_edge := floorf(p.z / Stage.CELL) * Stage.CELL
		for epsilon in [-0.0001, 0.0, 0.0001]:
			_check_road(stage, Vector3(x_edge + epsilon, p.y, p.z), hints)
			_check_road(stage, Vector3(p.x, p.y, z_edge + epsilon), hints)
			_check_road(stage, Vector3(x_edge + epsilon, p.y, z_edge + epsilon), hints)
	for p in [Vector3(1000000.0, 0.0, 1000000.0), Vector3(-1000000.0, 20.0, -1000000.0)]:
		_check_road(stage, p, PackedInt32Array([-1, 0, stage.points.size() / 2, stage.points.size() - 1, stage.points.size() + 100]))
		_check_water(stage, Vector2(p.x, p.z))
	for r in stage.rivers:
		var pts: PackedVector2Array = r.pts
		for k in range(0, pts.size(), 13):
			var p := pts[k]
			var next := mini(k + 1, pts.size() - 1)
			var previous := maxi(k - 1, 0)
			var tangent := (pts[next] - pts[previous]).normalized()
			var right := Vector2(-tangent.y, tangent.x)
			var half: float = r.half
			for off in [-40.0001, -40.0, -12.0001, -12.0, -half - 0.5001, -half - 0.5, 0.0, half + 0.5, half + 0.5001, 11.9999, 12.0, 12.0001, 40.0, 40.0001]:
				_check_water(stage, p + right * off)
			_check_water(stage, p.lerp(pts[next], 0.5))
			var cell := Vector2(floorf(p.x / Stage.CELL), floorf(p.y / Stage.CELL)) * Stage.CELL
			for epsilon in [-0.0001, 0.0, 0.0001]:
				_check_water(stage, Vector2(cell.x + epsilon, p.y))
				_check_water(stage, Vector2(p.x, cell.y + epsilon))
		# Exercise the road/stream crossing and both sampled endpoints explicitly.
		_check_water(stage, pts[0])
		_check_water(stage, pts[-1])
		var crossing: Vector3 = stage.points[r.cross]
		_check_water(stage, Vector2(crossing.x, crossing.z))
		_check_road(stage, crossing, PackedInt32Array([-1, r.cross, maxi(0, r.cross - 50)]))


func _check_candidates(stage: Stage) -> void:
	var road_entries := 0
	for cell in stage._locate_candidates:
		var expected := PackedInt32Array()
		for dx in [-1, 0, 1]:
			for dy in [-1, 0, 1]:
				expected.append_array(stage._hash.get(cell + Vector2i(dx, dy), PackedInt32Array()))
		_check(stage._locate_candidates[cell] == expected, "road candidate order at %s" % cell)
		road_entries += expected.size()
	_check(road_entries == stage.points.size() * 9, "road candidates must contain each point nine times")
	var river_entries := 0
	var river_points := 0
	for r in stage.rivers:
		river_points += r.pts.size()
	for cell in stage._river_candidates:
		var expected: Array[Vector2i] = []
		for dx in [-1, 0, 1]:
			for dy in [-1, 0, 1]:
				expected.append_array(stage._river_hash.get(cell + Vector2i(dx, dy), []))
		_check(stage._river_candidates[cell] == expected, "river candidate order at %s" % cell)
		river_entries += expected.size()
	_check(river_entries == river_points * 9, "river candidates must contain each point nine times")
	# Rebuilding indexes must not advance the simulation's global RNG.
	seed(891)
	var expected_random := randi()
	seed(891)
	stage._index()
	stage._index_rivers()
	_check(randi() == expected_random, "index rebuild consumed RNG")


func _check_fixtures(stage: Stage) -> void:
	# The left cell is visited before the right cell, despite its higher index.
	stage.points = PackedVector3Array([Vector3(1.0, 3.0, 0.0), Vector3(-1.0, 5.0, 0.0), Vector3(-1.0, 7.0, 0.0)])
	_set_road_data(stage)
	_check(stage.locate(Vector3.ZERO).index == 1, "cross-cell road tie changed")
	_check(stage.locate(Vector3.ZERO, 0).index == 0, "hint tie must retain ascending point order")
	_check_road(stage, Vector3.ZERO, PackedInt32Array([-1, 0, 1, 2, 100]))
	# The hint window deliberately wins within 30 m, even across a closer road.
	stage.points.resize(80)
	for i in stage.points.size():
		stage.points[i] = Vector3(1000.0 + i, 0.0, 1000.0)
	stage.points[0] = Vector3(0.0, 0.0, 1.0)
	stage.points[40] = Vector3.ZERO
	_set_road_data(stage)
	_check(stage.locate(Vector3.ZERO).index == 40, "unhinted crossing nearest changed")
	_check(stage.locate(Vector3.ZERO, 0).index == 0, "local hint preference changed")
	_check_road(stage, Vector3.ZERO, PackedInt32Array([-1, 0, 10, 30, 40, 79, 1000]))
	_check_road(stage, Vector3(-1000000.0, 0.0, -1000000.0), PackedInt32Array([-1, 0, 40, 1000]))
	_check(stage.locate(Vector3(-1000000.0, 0.0, -1000000.0), 0).index >= 0, "empty cells must retain a far hint candidate")
	stage.rivers.clear()
	for x in [1.0, -1.0]:
		stage.rivers.append({"pts": PackedVector2Array([Vector2(x, 0.0), Vector2(x, 2.0)]), "levels": PackedFloat32Array([2.0 if x > 0.0 else 5.0, 2.0 if x > 0.0 else 5.0]), "wet": PackedByteArray([1 if x > 0.0 else 0, 1]), "half": 3.0, "depth": 1.0, "cross": 0, "ford": false})
	stage._index_rivers()
	_check(stage._river_near(0.0, 0.0, 12.0).river == 1, "cross-cell river tie changed")
	_check(stage.water_level(0.0, 0.0) == -INF, "nearest dry point must remain dry")
	_check_water(stage, Vector2.ZERO)
	stage.rivers[1].wet[0] = 1
	_check(stage.water_level(0.0, 0.0) == 5.0, "wet flag change must not cache a water result")
	for q in [Vector2.ZERO, Vector2(13.0, 0.0), Vector2(12.9999, 0.0), Vector2(4.5, 0.0), Vector2(4.5001, 0.0), Vector2(41.0, 0.0), Vector2(40.9999, 0.0)]:
		_check_water(stage, q)
	_check(stage._river_near(13.0, 0.0, 12.0).is_empty(), "river reach must remain a strict comparison")
	_check_candidates(stage)
	# Geometry replacement and an empty stage must discard all old cell entries.
	stage.points = PackedVector3Array([Vector3(5000.0, 0.0, 5000.0), Vector3(5000.0, 0.0, 5002.0)])
	_set_road_data(stage)
	stage.rivers[0].pts = PackedVector2Array([Vector2(5000.0, 5000.0), Vector2(5000.0, 5002.0)])
	stage.rivers.resize(1)
	stage._index_rivers()
	_check(stage.locate(Vector3.ZERO).index == -1, "road rebuild retained an old cell")
	_check(stage._river_near(0.0, 0.0, 40.0).is_empty(), "river rebuild retained an old cell")
	_check_candidates(stage)
	stage.points.clear()
	stage.rivers.clear()
	stage._index()
	stage._index_rivers()
	_check(stage._locate_candidates.is_empty() and stage._river_candidates.is_empty(), "empty rebuild retained candidate lists")
	_check(stage.locate(Vector3.ZERO).index == -1, "empty stage road result changed")
	_check_water(stage, Vector2.ZERO)


func _set_road_data(stage: Stage) -> void:
	stage.dirs.resize(stage.points.size())
	stage.dirs.fill(Vector3.FORWARD)
	stage.widths.resize(stage.points.size())
	stage.widths.fill(3.4)
	stage._index()


func _check_road(stage: Stage, p: Vector3, hints: PackedInt32Array) -> void:
	for hint in hints:
		_check(stage.locate(p, hint) == _old_locate(stage, p, hint), "locate differs at %s, hint %d" % [p, hint])
	var old := _old_locate(stage, p, -1)
	var off := absf(old.offset)
	var w := stage.width_at(old.along)
	var surface := Surfaces.GRAVEL if off < w - 0.9 else Surfaces.LOOSE if off < w + 0.6 else Surfaces.GRASS
	_check(stage.surface_at(p) == surface, "surface differs at %s" % p)


func _check_water(stage: Stage, p: Vector2) -> void:
	for reach in [12.0, 40.0]:
		_check(stage._river_near(p.x, p.y, reach) == _old_river_near(stage, p.x, p.y, reach), "river query differs at %s, reach %s" % [p, reach])
	var near := _old_river_near(stage, p.x, p.y, 12.0)
	var water := -INF
	if not near.is_empty():
		var r: Dictionary = stage.rivers[near.river]
		if r.wet[near.point] != 0 and near.d <= r.half + 0.5:
			water = near.level
	_check(stage.water_level(p.x, p.y) == water, "water level differs at %s" % p)


func _old_locate(stage: Stage, p: Vector3, hint: int) -> Dictionary:
	var best := -1
	var best_d := INF
	if hint >= 0:
		for j in range(maxi(0, hint - 30), mini(stage.points.size(), hint + 30)):
			var d := Vector2(stage.points[j].x - p.x, stage.points[j].z - p.z).length_squared()
			if d < best_d:
				best_d = d
				best = j
		if best_d < 30.0 * 30.0:
			return stage._result(p, best)
	var c := Vector2i(floori(p.x / Stage.CELL), floori(p.z / Stage.CELL))
	for dx in [-1, 0, 1]:
		for dy in [-1, 0, 1]:
			for j in stage._hash.get(c + Vector2i(dx, dy), PackedInt32Array()):
				var d := Vector2(stage.points[j].x - p.x, stage.points[j].z - p.z).length_squared()
				if d < best_d:
					best_d = d
					best = j
	if best < 0:
		return {"index": -1, "along": 0.0, "offset": INF, "height": 0.0}
	return stage._result(p, best)


func _old_river_near(stage: Stage, x: float, z: float, reach: float) -> Dictionary:
	if stage.rivers.is_empty():
		return {}
	var c := Vector2i(floori(x / Stage.CELL), floori(z / Stage.CELL))
	var best := {}
	var best_d := reach * reach
	var q := Vector2(x, z)
	for dx in [-1, 0, 1]:
		for dy in [-1, 0, 1]:
			for id in stage._river_hash.get(c + Vector2i(dx, dy), []):
				var r: Dictionary = stage.rivers[id.x]
				var d := q.distance_squared_to(r.pts[id.y])
				if d < best_d:
					best_d = d
					best = {"river": id.x, "point": id.y}
	if best.is_empty():
		return best
	var r: Dictionary = stage.rivers[best.river]
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


func _check(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_failed = true
		push_error(message)
