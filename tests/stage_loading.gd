extends SceneTree
## Cooperative terrain construction must keep the same geometry and leave the
## main simulation counters still while loading. Run headless at fixed 120 Hz.

class SmallBuilder extends StageBuilder:
	func chunks() -> Array[Vector2i]:
		var all := super.chunks()
		var middle := all.size() / 2
		return [all[middle], all[middle + 1]]

const MAIN_FIXTURE := """
extends "res://main.gd"
func _ready() -> void:
	pass
"""

var failures := 0
var fixture: Node
var live_build := false
var heartbeats := 0
var progress_rows: Array[Dictionary] = []
var parent_under_test: Node3D


func _initialize() -> void:
	_run.call_deferred()


func _expect(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)


func _heartbeat() -> void:
	if live_build:
		heartbeats += 1
		fixture.call("_physics_process", 1.0 / 120.0)
		_expect(fixture.get("frame") == 41, "Loading advanced the main frame counter")
		_expect(fixture.get("clock") == -3.0, "Loading advanced the race clock")


func _progress(label: String, done: int, total: int) -> void:
	fixture.call("_build_progress", label, done, total)
	_expect(done >= 0 and (total == 0 or done <= total), "Invalid progress count")
	if label == "Preparing terrain":
		_expect(parent_under_test.get_node("Ground").get_child_count() == done, "Progress announced terrain before its collider was attached")
	if not progress_rows.is_empty() and progress_rows[-1].label == label:
		_expect(done >= int(progress_rows[-1].done), "Progress moved backwards within its phase")
	progress_rows.append({"label": label, "done": done, "total": total})


func _geometry(node: Node) -> Array:
	var out: Array = []
	if node is Node3D:
		out.append((node as Node3D).transform)
	if node is MeshInstance3D:
		var mesh: Mesh = node.mesh
		for surface in mesh.get_surface_count():
			out.append(mesh.surface_get_arrays(surface))
	if node is CollisionShape3D:
		var shape: Shape3D = node.shape
		if shape is ConcavePolygonShape3D:
			out.append(shape.get_faces())
		elif shape is ConvexPolygonShape3D:
			out.append(shape.points)
	for child in node.get_children():
		out.append(_geometry(child))
	return out


func _run() -> void:
	await process_frame # Register autoloads before dynamically compiling main.
	var script := GDScript.new()
	script.source_code = MAIN_FIXTURE
	if script.reload() != OK:
		quit(1)
		return
	fixture = script.new()
	fixture.process_mode = Node.PROCESS_MODE_DISABLED
	root.add_child(fixture)
	fixture.call("_build_scene")
	fixture.set("building", true)
	fixture.set("frame", 41)
	fixture.set("clock", -3.0)
	process_frame.connect(_heartbeat)
	seed(1)
	var stage := Stage.new()
	stage.generate(300.0 + Stage.RUNOUT)
	var baseline := SmallBuilder.new(stage)
	var cooperative := SmallBuilder.new(stage)
	var first := Node3D.new()
	var second := Node3D.new()
	root.add_child(first)
	root.add_child(second)
	parent_under_test = first
	live_build = true
	var sync_count: int = await baseline.build(first, _progress, false)
	live_build = false
	_expect(heartbeats == 0, "Synchronous automation path yielded a process frame")
	progress_rows.clear()
	parent_under_test = second
	live_build = true
	var async_count: int = await cooperative.build(second, _progress, true)
	live_build = false
	_expect(heartbeats > 0, "Cooperative build never let the UI process a frame")
	_expect(sync_count == 2 and async_count == sync_count, "Chunk count changed")
	_expect(baseline.ground_map.get_data() == cooperative.ground_map.get_data(), "Ground map differs between scheduling modes")
	_expect(baseline.ground_origin == cooperative.ground_origin, "Ground-map origin changed")
	for key in ["tree_spots", "tree_colliders", "rock_spots", "grass_spots", "fern_spots", "stump_spots"]:
		_expect(var_to_bytes(baseline.get(key)) == var_to_bytes(cooperative.get(key)), "Placement changed: " + key)
	_expect(var_to_bytes(_geometry(first)) == var_to_bytes(_geometry(second)), "Attached mesh/collision geometry changed")
	var complete := false
	for row in progress_rows:
		if row.label == "Preparing terrain" and row.done == async_count:
			complete = true
	_expect(complete, "No completed attachment progress was reported")
	print("stage_loading: %d chunks, %d responsive frames, %d failures" % [async_count, heartbeats, failures])
	# Release fixture references before freeing the owned tree/data nodes.
	process_frame.disconnect(_heartbeat)
	parent_under_test = null
	first.free()
	second.free()
	fixture.free()
	fixture = null
	stage.free()
	PhysicsServer3D.set_active(true)
	await process_frame
	quit(1 if failures else 0)
