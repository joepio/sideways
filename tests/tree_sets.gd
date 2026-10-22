extends SceneTree
## Real populated MultiMesh buffers and camera lifecycle, not a source-text test.
var checks := 0
var failures: Array[String] = []
var spots: Array[Transform3D] = []
var variants := PackedInt32Array()
var eyes: Array = []
var sets: TreeSets
var viewports: Array[SubViewport] = []
var _headless := false

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	_headless = DisplayServer.get_name() == "headless"
	var positions := [Vector3(0,0,-5), Vector3(0,2,-20), Vector3(0,0,-32), Vector3(0,0,-35), Vector3(0,0,-38), Vector3(0,0,-80), Vector3(0,0,-92), Vector3(0,0,20), Vector3(0,0,48), Vector3(8,0,0), Vector3(30,0,0), Vector3(150,0,-5), Vector3(150,0,-20), Vector3(150,0,-80), Vector3(18,0,-18)]
	for i in positions.size():
		spots.append(Transform3D(Basis(Vector3.UP, float(i) * 0.21).scaled(Vector3(0.8,1.2,0.9)), positions[i]))
		variants.append(i % 3)
	for i in 2:
		var viewport := SubViewport.new()
		viewport.size = Vector2i(1600,900)
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		root.add_child(viewport)
		viewports.append(viewport)
		var camera := Camera3D.new()
		camera.position = Vector3(float(i) * 150.0, 6.0, 0.0)
		camera.fov = 60.0
		camera.cull_mask = TreeSets.cull_mask(i)
		viewport.add_child(camera)
		camera.make_current()
		eyes.append(camera)
	sets = TreeSets.new()
	for variant in 3:
		var trio: Array = []
		for level in 3:
			var mesh := BoxMesh.new()
			mesh.size = Vector3(1,4,1)
			trio.append(mesh)
		sets.meshes.append(trio)
	sets.shadow_tip = Vector2(0.0,-40.0)
	sets.setup(spots,variants)
	sets.eyes = func() -> Array: return eyes
	root.add_child(sets)
	sets.set_process(false)
	sets._process(0.0)
	_check(sets._views.size() == 2 and sets.get_child_count() == 18, "initial nine sets per view missing")
	_expect(0,0,[0,1,2,3,9,14])
	_expect(0,1,[0,1,2,3,7,9,10,14])
	_expect(0,2,[1,2,3,4,5,14])
	_expect(1,0,[11,12])
	_expect(1,2,[12,13])
	for index in 2:
		for trio: Array in sets._views[index].sets:
			for node: MultiMeshInstance3D in trio:
				_check(node.layers & (eyes[index] as Camera3D).cull_mask != 0, "own view cannot see its tree set")
				_check(node.layers & (eyes[1-index] as Camera3D).cull_mask == 0, "tree set leaks into another view")
				_check(not node.multimesh.use_custom_data and not node.multimesh.use_colors, "extra per-instance payload")
				_check(node.physics_interpolation_mode == Node.PHYSICS_INTERPOLATION_MODE_OFF and not node.is_physics_interpolated_and_enabled(), "render-frame tree slots inherited physics interpolation")
	for index in TreeSets.MAX_VIEWS:
		var mask := TreeSets.cull_mask(index)
		_check(mask & 1 != 0 and mask & (1 << 8) != 0, "non-tree scenery/body layers removed")
		for other in TreeSets.MAX_VIEWS:
			_check((mask & (1 << (TreeSets.LAYER0 + other)) != 0) == (index == other), "view mask isolation failed")
	var camera: Camera3D = eyes[0]
	var node: MultiMeshInstance3D = sets._views[0].sets[0][0]
	var shown := node.multimesh
	var old_buffer := shown.buffer
	camera.position.x = 0.5
	sets._process(0.0)
	_check(node.multimesh == shown and node.multimesh.buffer == old_buffer and int(sets._views[0].swap_at) == 0, "sub-threshold motion refilled visible data")
	camera.position.x = 3.0
	sets._process(0.0)
	var queued_at: int = sets._views[0].swap_at
	var spare := node.get_meta("spare") as MultiMesh
	_check(queued_at == Engine.get_frames_drawn() + 2, "refill did not reserve two drawn frames")
	_check(node.multimesh == shown and shown.buffer == old_buffer, "refill changed the currently shown buffer")
	sets._process(0.0)
	_check(node.multimesh == shown, "spare became visible before two draws")
	if not _headless:
		for attempt in 8:
			await RenderingServer.frame_post_draw
			var drawn := Engine.get_frames_drawn()
			sets._process(0.0)
			if drawn < queued_at:
				_check(node.multimesh == shown, "spare became visible early")
			else:
				break
		_check(Engine.get_frames_drawn() >= queued_at and node.multimesh == spare and int(sets._views[0].swap_at) == 0, "actual two-draw swap did not complete")
		_expect(0,0,[0,1,2,3,9,14]) # Actual freshly shown GPU buffer, same stationary tree identities.
	# A real reset while a spare is pending must replace the old region now.
	camera.position.x = 0.0
	sets._process(0.0)
	camera.position.x = 3.0
	sets._process(0.0)
	camera.position.x = 150.0
	sets._process(0.0)
	_check(int(sets._views[0].swap_at) == 0 and sets._views[0].at == camera.position, "reset kept stale pending refill")
	_expect(0,0,[11,12])
	# Disappear during a queued refill; return at a wholly different place.
	camera.position.x = 153.0
	sets._process(0.0)
	_check(int(sets._views[0].swap_at) > 0, "hidden-view fixture did not queue a refill")
	eyes[0] = null
	sets._process(0.0)
	_check(not node.visible and int(sets._views[0].swap_at) == 0, "hidden view retained a pending swap")
	camera.position.x = 0.0
	eyes[0] = camera
	sets._process(0.0)
	_expect(0,0,[0,1,2,3,9,14])
	_check(node.visible and int(sets._views[0].swap_at) == 0, "returning view did not refill immediately")
	# Actual projection changes at a stationary eye change which tree fits.
	camera.keep_aspect = Camera3D.KEEP_WIDTH
	camera.fov = 40.0
	sets._process(0.0)
	_expect(0,0,[0,1,2,3,9])
	camera.fov = 60.0
	sets._process(0.0)
	_expect(0,0,[0,1,2,3,9,14])
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.fov = 40.0
	viewports[0].size = Vector2i(900,900)
	sets._process(0.0)
	_expect(0,0,[0,1,2,3,9])
	viewports[0].size = Vector2i(1800,900)
	sets._process(0.0)
	_expect(0,0,[0,1,2,3,9,14])
	# Camera replacement must invalidate even an identical pose/projection.
	var replacement := Camera3D.new()
	replacement.position = camera.position
	replacement.keep_aspect = camera.keep_aspect
	replacement.fov = camera.fov
	replacement.cull_mask = camera.cull_mask
	viewports[0].add_child(replacement)
	eyes[0] = replacement
	sets._process(0.0)
	_check(int(sets._views[0].camera) == replacement.get_instance_id() and int(sets._views[0].swap_at) == 0, "camera replacement did not refill immediately")
	_expect(1,0,[11,12]) # Independent view has not moved or changed.
	# Removing all views hides every real draw without freeing/recreating it.
	eyes.clear()
	sets._process(0.0)
	_check(sets.get_child_count() == 18, "lifecycle added draw nodes")
	for child in sets.get_children(): _check(not child.visible, "removed camera still draws trees")
	sets.eyes = Callable()
	sets.queue_free()
	for viewport in viewports: viewport.queue_free()
	await process_frame
	if not _headless: await RenderingServer.frame_post_draw
	if failures.is_empty():
		print("tree sets: %d actual-buffer/lifecycle checks passed; drawn_delay_checked=%s" % [checks, not _headless])
	else:
		for message in failures: push_error(message)
	quit(0 if failures.is_empty() else 1)

func _expect(view: int, level: int, expected: Array) -> void:
	var actual: Array[int] = []
	for variant in sets.meshes.size():
		var node: MultiMeshInstance3D = sets._views[view].sets[variant][level]
		var mm := node.multimesh
		var buffer := mm.buffer
		_check(buffer.size() == mm.instance_count * 12, "wrong packed transform stride/capacity")
		for instance in mm.visible_instance_count:
			var o := instance * 12
			if o + 11 >= buffer.size():
				_check(false,"active instance exceeds actual buffer")
				continue
			var xf := Transform3D(Basis(Vector3(buffer[o],buffer[o+4],buffer[o+8]),Vector3(buffer[o+1],buffer[o+5],buffer[o+9]),Vector3(buffer[o+2],buffer[o+6],buffer[o+10])),Vector3(buffer[o+3],buffer[o+7],buffer[o+11]))
			var found := -1
			for i in spots.size():
				if xf.is_equal_approx(spots[i]):
					found = i
					break
			_check(found >= 0, "buffer changed authored placement/rotation/scale")
			if found >= 0:
				_check(variants[found] == variant and not found in actual, "wrong mesh variant or duplicate placement")
				_check(node.custom_aabb.has_point(xf.origin), "selected origin outside actual draw bounds")
				actual.append(found)
	actual.sort()
	_check(actual == expected, "wrong actual population view%d level%d: %s expected %s" % [view,level,actual,expected])

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
