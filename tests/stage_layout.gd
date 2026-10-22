extends SceneTree
## Test the generated polyline, not the layout's plan or interpolation formula.
## The broad phase below uses segment AABBs; nearby nonadjacent segments receive
## an independent intersection and closest-point check at full 2 m resolution.

var _failed := false
var _checks := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var stage := Stage.new()
	for metres in [2000.0, 8000.0]:
		for stage_seed in [1, 7, 42, 4242, 90210, 123456]:
			seed(stage_seed)
			stage._layout(metres)
			var first := stage.points.duplicate()
			var next_random := randi()
			seed(stage_seed)
			stage._layout(metres)
			_check(stage.points.to_byte_array() == first.to_byte_array(), "same seed changed points")
			_check(randi() == next_random, "same seed changed subsequent RNG state")
			_check_shape(stage.points, metres, stage_seed)
	for metres in [0.0, 0.5, 119.5, 120.0, 120.5, 2001.5]:
		seed(73)
		stage._layout(metres)
		_check(stage.points.size() == ceili(metres / Stage.STEP) + 1, "partial length sample count")
	# The real generation pipeline must retain determinism after profiling,
	# ledges, streams and road surfaces, rather than only in the layout fixture.
	seed(31415)
	stage.generate(2000.0)
	var generated := stage.points.to_byte_array()
	var widths := stage.widths.to_byte_array()
	var surfaces := stage.road_surfaces.duplicate()
	var next_random := randi()
	seed(31415)
	stage.generate(2000.0)
	_check(stage.points.to_byte_array() == generated, "full generation changed centreline")
	_check(stage.widths.to_byte_array() == widths, "full generation changed widths")
	_check(stage.road_surfaces == surfaces, "full generation changed surfaces")
	_check(randi() == next_random, "full generation changed subsequent RNG state")
	stage.free()
	if not _failed:
		print("stage layout: %d geometry, clearance and determinism checks passed" % _checks)
	quit(1 if _failed else 0)


func _check_shape(points: PackedVector3Array, metres: float, stage_seed: int) -> void:
	_check(points.size() == ceili(metres / Stage.STEP) + 1, "route must stop at requested length")
	_check(points[0] == Vector3.ZERO, "route origin")
	var flat := PackedVector2Array()
	var previous_direction := Vector2(0.0, -1.0)
	var corners := 0
	var corner_turn := 0.0
	var tight_corners := 0
	var tight_metres := 0.0
	var in_tight := false
	var straight_metres := 0.0
	var longest_straight := 0.0
	var peak_curvature := 0.0
	for i in points.size():
		var p := points[i]
		_check(p.is_finite() and p.y == 0.0, "finite horizontal layout")
		flat.append(Vector2(p.x, p.z))
		if i == 0:
			continue
		var segment := flat[i] - flat[i - 1]
		_check(absf(segment.length() - Stage.STEP) < 0.002, "uniform physical sample spacing")
		var direction := segment.normalized()
		var heading := atan2(direction.x, -direction.y)
		_check(absf(heading) <= deg_to_rad(50.05), "route heading escaped forward corridor")
		_check(segment.y < 0.0, "route reversed its forward direction")
		if i <= 60:
			_check(absf(p.x) < 0.00001 and absf(p.z + i * Stage.STEP) < 0.00001, "initial 120 m grid straight")
		var turn := absf(previous_direction.angle_to(direction))
		var curvature := turn / Stage.STEP
		peak_curvature = maxf(peak_curvature, curvature)
		if curvature > 0.00075:
			corner_turn += turn
		else:
			if corner_turn >= deg_to_rad(15.0):
				corners += 1
			corner_turn = 0.0
		if curvature > 1.0 / 45.0:
			if not in_tight:
				tight_corners += 1
			in_tight = true
			tight_metres += Stage.STEP
		elif curvature < 1.0 / 60.0:
			in_tight = false
		# A perceptually straight run includes shallow easing tails, not only
		# segments which the generator happened to label as a straight.
		if curvature < 1.0 / 400.0:
			straight_metres += Stage.STEP
			longest_straight = maxf(longest_straight, straight_metres)
		else:
			straight_metres = 0.0
		previous_direction = direction
	if corner_turn >= deg_to_rad(15.0):
		corners += 1
	_check(peak_curvature < 1.0 / 13.5, "corner contains a kink tighter than supported tyres/pace notes")
	_check(corners >= int(metres / 700.0), "too few distinct corners")
	_check(tight_corners >= int(metres / 1600.0), "too few genuinely tight corner regions")
	_check(tight_metres >= metres * 0.01, "tight corners are only isolated numerical spikes")
	_check(longest_straight <= 500.0, "long nearly-straight section dominates the route")
	_check_clearance(flat)
	print("stage layout: seed %d, %.0f m, %d corners/%d tight, %.0f tight m, longest straight %.0f m, peak curvature %.5f" % [stage_seed, metres, corners, tight_corners, tight_metres, longest_straight, peak_curvature])


func _check_clearance(points: PackedVector2Array) -> void:
	var cells := {}
	var nearby_pairs := 0
	for i in range(points.size() - 1):
		var a := points[i]
		var b := points[i + 1]
		var low := a.min(b)
		var high := a.max(b)
		var query_low := Vector2i(floori((low.x - 70.0) / 70.0), floori((low.y - 70.0) / 70.0))
		var query_high := Vector2i(floori((high.x + 70.0) / 70.0), floori((high.y + 70.0) / 70.0))
		var visited := {}
		for x in range(query_low.x, query_high.x + 1):
			for y in range(query_low.y, query_high.y + 1):
				var candidates: Array = cells.get(Vector2i(x, y), [])
				for candidate in candidates:
					var j: int = candidate
					# Exclude only segment pairs within 120 m along the road.
					if (i - j - 1) * Stage.STEP <= 120.0 or visited.has(j):
						continue
					visited[j] = true
					var c := points[j]
					var d := points[j + 1]
					nearby_pairs += 1
					_check(Geometry2D.segment_intersects_segment(a, b, c, d) == null, "nonadjacent road segments cross")
					var distance := minf(a.distance_to(Geometry2D.get_closest_point_to_segment(a, c, d)), b.distance_to(Geometry2D.get_closest_point_to_segment(b, c, d)))
					distance = minf(distance, c.distance_to(Geometry2D.get_closest_point_to_segment(c, a, b)))
					distance = minf(distance, d.distance_to(Geometry2D.get_closest_point_to_segment(d, a, b)))
					_check(distance >= 70.0, "nonadjacent road segments lost 70 m clearance")
		var cell_low := Vector2i(floori(low.x / 70.0), floori(low.y / 70.0))
		var cell_high := Vector2i(floori(high.x / 70.0), floori(high.y / 70.0))
		for x in range(cell_low.x, cell_high.x + 1):
			for y in range(cell_low.y, cell_high.y + 1):
				var key := Vector2i(x, y)
				if not cells.has(key):
					cells[key] = []
				cells[key].append(i)
	_check(nearby_pairs > 0, "clearance broad phase exercised no actual segment pairs")


func _check(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_failed = true
		push_error(message)
