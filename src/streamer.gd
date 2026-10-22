class_name Streamer
extends Node
## Keeps the near blocks of trees and ground cover out of the renderer while
## no camera is close to them. Their visibility ranges already hide them, but
## the renderer tests every instance in the scenario against every view and
## shadow split before it gets to the range: 23k blocks along a stage were
## most of the CPU frame in split screen. A hidden instance leaves the cull
## tree, so only the few hundred near the cameras are tested.

const MARGIN := 14.0 ## metres beyond a block's range: covers a few frames at full speed
const EVERY := 3 ## frames between updates

## Returns the cameras' positions this frame.
var eyes: Callable
var _cell := {} ## reach -> {Vector2i: Array of [node, centre]}
var _shown := {} ## node -> true
var _frame := 0


## Takes over every visible GeometryInstance3D under `root` with a
## "stream_reach" meta (the visibility range end), hiding it until a camera
## comes near. Stripped (already hidden) ones stay hidden.
func adopt(root: Node) -> void:
	for n in root.find_children("*", "GeometryInstance3D", true, false):
		var g := n as GeometryInstance3D
		if not g.has_meta("stream_reach") or not g.visible:
			continue
		var reach := float(g.get_meta("stream_reach")) + MARGIN
		var centre := g.global_transform * g.get_aabb().get_center()
		if not _cell.has(reach):
			_cell[reach] = {}
		var key := Vector2i(floori(centre.x / reach), floori(centre.z / reach))
		var cells: Dictionary = _cell[reach]
		if not cells.has(key):
			cells[key] = []
		cells[key].append([g, Vector2(centre.x, centre.z)])
		g.visible = false
	_update()


func _process(_delta: float) -> void:
	_frame += 1
	if _frame % EVERY == 0:
		_update()


func _update() -> void:
	if not eyes.is_valid():
		return
	var at: Array = eyes.call()
	var now := {}
	for reach in _cell:
		var cells: Dictionary = _cell[reach]
		var r2: float = reach * reach
		for eye in at:
			var e := Vector2(eye.x, eye.z)
			var c := Vector2i(floori(e.x / reach), floori(e.y / reach))
			for dx in [-1, 0, 1]:
				for dz in [-1, 0, 1]:
					for entry in cells.get(c + Vector2i(dx, dz), []):
						if e.distance_squared_to(entry[1]) < r2:
							now[entry[0]] = true
	for g in _shown:
		if not now.has(g) and is_instance_valid(g):
			g.visible = false
	for g in now:
		if not _shown.has(g):
			g.visible = true
	_shown = now
