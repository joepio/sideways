class_name TreeSets
extends Node3D
## The near and mid trees, one small set per split-screen view. Each view's
## camera sees only its own layer, and the sets are refilled from a grid of
## tree spots as the camera moves. Blocks of trees with visibility ranges
## drew every tree in a block with the near (or mid) mesh until the whole
## block was out of range, and were hundreds of draws per view and shadow
## split; this draws only the trees that show that level, in 9 draws.

const LAYER0 := 10 ## render layer bit of view 0; view i uses LAYER0 + i
const MAX_VIEWS := 8
const CELL := 16.0
const MOVE := 2.0 ## metres a camera moves before its sets are refilled
const TURN := 8.0 ## degrees a camera turns before its sets are refilled
const SLACK := 20.0 ## degrees kept beyond each side of the view
const CLOSE := 10.0 ## metres round the camera kept whatever the direction

## The cameras per view index (null where a view has none).
var eyes: Callable
var near_end := Forest.NEAR_END
var mid_end := Forest.MID_END
var meshes: Array = [] ## per variant: [near, shade, mid]
## Ground offset from a tree to the tip of its shadow (the tallest tree's,
## on flat ground): a tree behind the camera can still shade the view.
var shadow_tip := Vector2.ZERO

var _spots: Array[Transform3D] = []
var _variant := PackedInt32Array()
var _cells := {} ## Vector2i -> PackedInt32Array of spot indices
var _views: Array = [] ## per view: {"at": Vector3, "sets": [[MultiMeshInstance3D x3] per variant]}


## Every camera's cull mask: all layers but the other views' tree layers.
static func cull_mask(view: int) -> int:
	var all := (1 << 20) - 1
	var views := ((1 << MAX_VIEWS) - 1) << LAYER0
	return (all & ~views) | (1 << (LAYER0 + mini(view, MAX_VIEWS - 1)))


func setup(spots: Array[Transform3D], variant: PackedInt32Array) -> void:
	_spots = spots
	_variant = variant
	for i in spots.size():
		var o := spots[i].origin
		var key := Vector2i(floori(o.x / CELL), floori(o.z / CELL))
		if not _cells.has(key):
			_cells[key] = PackedInt32Array()
		var list: PackedInt32Array = _cells[key]
		list.append(i)
		_cells[key] = list


func _process(_delta: float) -> void:
	if not eyes.is_valid() or not is_visible_in_tree():
		return
	var at: Array = eyes.call()
	for v in mini(at.size(), MAX_VIEWS):
		while _views.size() <= v:
			_views.append(_new_view(_views.size()))
		var view: Dictionary = _views[v]
		if at[v] == null:
			_show(view, false)
			continue
		_show(view, true)
		var cam: Camera3D = at[v]
		var eye := cam.global_position
		var fwd := -cam.global_basis.z
		fwd = Vector3(fwd.x, 0.0, fwd.z).normalized()
		if view.at != null and (view.at as Vector3).distance_to(eye) < MOVE and rad_to_deg((view.fwd as Vector3).angle_to(fwd)) < TURN:
			continue
		view.at = eye
		view.fwd = fwd
		# Half the horizontal field of view (fov is vertical), plus slack.
		var size := cam.get_viewport().get_visible_rect().size
		var half := atan(tan(deg_to_rad(cam.fov) * 0.5) * size.x / maxf(size.y, 1.0))
		_fill(view, eye, Vector2(fwd.x, fwd.z), cos(minf(half + deg_to_rad(SLACK), PI)))
	for v in range(at.size(), _views.size()):
		_show(_views[v], false)


func _new_view(index: int) -> Dictionary:
	var sets := []
	for v in meshes.size():
		var trio := []
		for level in 3:
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = meshes[v][level]
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = mm
			mmi.layers = 1 << (LAYER0 + index)
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY if level == 1 else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(mmi)
			trio.append(mmi)
		sets.append(trio)
	return {"at": null, "fwd": Vector3.FORWARD, "sets": sets}


func _show(view: Dictionary, on: bool) -> void:
	for trio in view.sets:
		for mmi in trio:
			mmi.visible = on
	if not on:
		view.at = null


## Refills a view's sets for a camera at `eye` looking along `fwd`. The
## trees' own shaders dissolve the levels into each other
## (lod_fade.gdshaderinc); the sets only need to hold every tree that is
## inside a level's fade and in front of the camera (`cone`: the cosine of
## the half angle kept). The shadow set keeps the trees whose shadow tip
## is in front too.
func _fill(view: Dictionary, eye: Vector3, fwd: Vector2, cone: float) -> void:
	var slack := MOVE * 2.0
	var near_out := near_end + Forest.FADE + slack
	var mid_in := maxf(near_end - Forest.FADE - slack, 0.0)
	var mid_out := mid_end + Forest.FADE * 2.0 + slack
	var bufs := []
	var counts := []
	for v in meshes.size():
		bufs.append([PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array()])
		counts.append([0, 0, 0])
	var e := Vector2(eye.x, eye.z)
	var c := Vector2i(floori(eye.x / CELL), floori(eye.z / CELL))
	var r := ceili(mid_out / CELL)
	var near2 := near_out * near_out
	var mid_in2 := mid_in * mid_in
	var mid2 := mid_out * mid_out
	for dz in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var list = _cells.get(c + Vector2i(dx, dz))
			if list == null:
				continue
			for i in list:
				var xf := _spots[i]
				var to := Vector2(xf.origin.x, xf.origin.z) - e
				var d2 := to.length_squared()
				if d2 > mid2:
					continue
				var v := _variant[i]
				var seen := d2 < CLOSE * CLOSE or to.dot(fwd) > cone * sqrt(d2)
				if d2 < near2:
					var tip := to + shadow_tip
					if seen or tip.dot(fwd) > cone * tip.length():
						_put(bufs[v][1], xf)
						counts[v][1] += 1
					if seen:
						_put(bufs[v][0], xf)
						counts[v][0] += 1
				if d2 > mid_in2 and seen:
					_put(bufs[v][2], xf)
					counts[v][2] += 1
	var box := AABB(eye - Vector3(mid_out, 80.0, mid_out), Vector3(mid_out * 2.0, 160.0, mid_out * 2.0))
	for v in meshes.size():
		var trio: Array = view.sets[v]
		for level in 3:
			_load(trio[level], bufs[v][level], counts[v][level], box)


static func _put(buf: PackedFloat32Array, xf: Transform3D) -> void:
	var b := xf.basis
	var o := xf.origin
	buf.append_array([b.x.x, b.y.x, b.z.x, o.x, b.x.y, b.y.y, b.z.y, o.y, b.x.z, b.y.z, b.z.z, o.z])


## Grows the MultiMesh in steps and draws only the first `count`, so a
## refill rarely reallocates.
static func _load(mmi: MultiMeshInstance3D, buf: PackedFloat32Array, count: int, box: AABB) -> void:
	var mm := mmi.multimesh
	if count > mm.instance_count:
		mm.instance_count = maxi(count + count / 2, 16)
	var full := buf.duplicate()
	full.resize(mm.instance_count * 12)
	mm.buffer = full
	mm.visible_instance_count = count
	mmi.custom_aabb = box
