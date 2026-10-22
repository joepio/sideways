extends SceneTree
## Visual road joins must not alter the physical ribbon. Track stamps must
## also survive lateral sliding and stationary wheelspin.

var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_check_tracks()
	for stage_seed in [1, 4242]:
		seed(stage_seed)
		var stage := Stage.new()
		stage.generate(500.0)
		var builder := StageBuilder.new(stage)
		# Force a bridge even if this seed would not generate one. Its deck
		# spans the stream half-width plus six metres on either side.
		var crossing := stage.points.size() / 2
		stage.rivers = [{"ford": false, "half": 4.0, "cross": crossing}]
		# This fixture tests only the open bridge span, not a carved stream.
		stage._river_hash.clear()
		stage._river_candidates.clear()
		var road := builder.road()
		var arrays: Array = road.arrays
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var faces: PackedVector3Array = road.faces
		_expect(indices.size() > faces.size(), "Shoulder joins must add visible faces")
		for index in faces.size():
			if faces[index] != vertices[indices[index]]:
				_expect(false, "Shoulder fill changed the physical road")
				break
		for channel in [Mesh.ARRAY_NORMAL, Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2, Mesh.ARRAY_COLOR]:
			_expect(arrays[channel].size() == vertices.size(), "Shoulder vertex attribute mismatch")
		var rows := stage.points.size()
		var cols := faces.size() / (6 * (rows - 1)) + 1
		for added in range(faces.size(), indices.size()):
			var shoulder_vertex := indices[added] - rows * cols
			var row := (shoulder_vertex % (rows * 2)) / 2
			if abs(row - crossing) <= 5:
				_expect(false, "Soil curtain intrudes into the bridge's open span")
				break
		for vertex in vertices:
			if not vertex.is_finite():
				_expect(false, "Non-finite road/shoulder vertex")
				break
		stage.free()
	if not failures.is_empty():
		for failure in failures:
			printerr("road visuals: ", failure)
		quit(1)
		return
	print("road visuals: unchanged collision ribbon, finite soil joins, lateral tracks and bounded stationary scuff passed")
	quit()


func _check_tracks() -> void:
	var tracks := TrackMap.new(600.0)
	var tyre := RefCounted.new()
	tracks.stamp(tyre, 10.0, 0.0, 1.0, 0.0)
	var parked := tracks.images[0].get_pixel(64, 40)
	for tick in 24:
		tracks.upload()
		tracks.stamp(tyre, 10.0, 0.0, 1.0, 0.0)
	_expect(tracks.images[0].get_pixel(64, 40) == parked, "Parked tyre deepened its track")
	# Move laterally within the SAME longitudinal row. Every crossed column
	# should get a mark, not merely the destination.
	tracks.stamp(tyre, 10.0, 0.4, 1.0, 0.8)
	for column in range(67, 83):
		_expect(tracks.images[0].get_pixel(column, 40).r > 0.0, "Missing lateral slide column %d" % column)
	var before := tracks.images[0].get_pixel(84, 40)
	for tick in 24:
		tracks.upload()
		tracks.stamp(tyre, 10.0, 0.4, 1.0, 1.0)
	var after := tracks.images[0].get_pixel(84, 40)
	_expect(after.r > before.r and after.g > before.g, "Stationary wheelspin left no scuff")
	_expect(after.r < 1.0, "Stationary scuff saturated too quickly")
	# Leaving contact clears history: returning must not join across a jump.
	tracks.stamp(tyre, 10.0, 9.0, 0.0, 0.0)
	tracks.stamp(tyre, 30.0, -0.4, 1.0, 0.0)
	_expect(tracks.images[0].get_pixel(64, 80).r == 0.0, "Airborne wheel drew a connecting streak")


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
