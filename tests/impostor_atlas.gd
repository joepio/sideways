extends SceneTree
## Validate the actual PNG pair without a renderer or texture-import settings.
## A stale camera or mesh between bake passes can misregister their silhouettes.

const ATLAS_SIZE := Vector2i(2048, 1536)
const CELL_SIZE := Vector2i(256, 512)
const VIEWS := 8
const TREES := ["a", "b", "c"]

var _failed := false
var _checks := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var albedo := _load_png("res://assets/trees/impostor_albedo.png")
	var normal := _load_png("res://assets/trees/impostor_normal.png")
	if albedo == null or normal == null:
		quit(1)
		return
	_check(albedo.get_size() == ATLAS_SIZE, "albedo must be 2048x1536")
	_check(normal.get_size() == ATLAS_SIZE, "normal must be 2048x1536")
	if _failed:
		quit(1)
		return
	_check_mesh_sizes()
	var a := albedo.get_data()
	var n := normal.get_data()
	for tree_i in TREES.size():
		for view_i in VIEWS:
			var cell := Rect2i(Vector2i(view_i, tree_i) * CELL_SIZE, CELL_SIZE)
			_check_cell(a, n, cell, "tree %s view %d" % [TREES[tree_i], view_i])
	if not _failed:
		print("impostor atlas: %d checks passed across 24 paired 256x512 cells" % _checks)
	quit(1 if _failed else 0)


func _load_png(path: String) -> Image:
	var img := Image.new()
	var error := img.load(path)
	_check(error == OK, "cannot load %s: %s" % [path, error_string(error)])
	if error != OK:
		return null
	_check(img.get_format() == Image.FORMAT_RGBA8, path + " must retain RGBA8 alpha")
	if img.get_format() != Image.FORMAT_RGBA8:
		return null
	return img


func _check_mesh_sizes() -> void:
	_check(Forest.VARIANTS == TREES, "Forest variant order must match the atlas rows")
	_check(Forest.IMPOSTOR_SIZE.size() == TREES.size(), "Forest needs one impostor size per atlas row")
	if Forest.IMPOSTOR_SIZE.size() != TREES.size():
		return
	for tree_i in TREES.size():
		var path := "res://assets/trees/fir_%s_near.res" % TREES[tree_i]
		var mesh := load(path) as ArrayMesh
		_check(mesh != null, "cannot load impostor source mesh: " + path)
		if mesh == null:
			continue
		# KEEP_HEIGHT framing in the baker: the cell is twice as tall as wide.
		var aabb := mesh.get_aabb()
		var radius := maxf(maxf(absf(aabb.position.x), absf(aabb.end.x)), maxf(absf(aabb.position.z), absf(aabb.end.z)))
		var expected := maxf(aabb.end.y, radius * 4.0)
		var actual: float = Forest.IMPOSTOR_SIZE[tree_i]
		_check(absf(actual - expected) <= 0.0001, "tree %s: Forest.IMPOSTOR_SIZE %.8f differs from current mesh bake size %.8f" % [TREES[tree_i], actual, expected])


func _check_cell(a: PackedByteArray, n: PackedByteArray, cell: Rect2i, label: String) -> void:
	var mismatches := 0
	var first_mismatch := Vector2i(-1, -1)
	var albedo_partial := 0
	var normal_partial := 0
	var albedo_covered := 0
	var normal_covered := 0
	for y in range(cell.position.y, cell.end.y):
		for x in range(cell.position.x, cell.end.x):
			var i := (y * ATLAS_SIZE.x + x) * 4 + 3
			var aa := a[i]
			var na := n[i]
			if aa != na:
				if mismatches == 0:
					first_mismatch = Vector2i(x, y)
				mismatches += 1
			if aa != 0 and aa != 255:
				albedo_partial += 1
			if na != 0 and na != 255:
				normal_partial += 1
			if aa > 0:
				albedo_covered += 1
			if na > 0:
				normal_covered += 1
	_check(mismatches == 0, "%s: %d unequal alpha bytes; first atlas pixel %s" % [label, mismatches, first_mismatch])
	_check(albedo_partial == 0, "%s: albedo has %d nonbinary alpha bytes" % [label, albedo_partial])
	_check(normal_partial == 0, "%s: normal has %d nonbinary alpha bytes" % [label, normal_partial])
	var pixels := CELL_SIZE.x * CELL_SIZE.y
	_check(albedo_covered > 0 and albedo_covered < pixels, label + ": albedo silhouette must include tree and background")
	_check(normal_covered > 0 and normal_covered < pixels, label + ": normal silhouette must include tree and background")


func _check(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_failed = true
		push_error(message)
