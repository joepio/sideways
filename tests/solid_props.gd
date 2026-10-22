extends SceneTree
## Solid scenery must match drawn variant/transform and remain on layer 1 for
## car bodies, tyres and the camera. Uses actual Jolt queries, not render LODs.

var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_check_generated_trees()
	_check_asset_shapes()
	var world := Node3D.new()
	root.add_child(world)
	var small := BoxMesh.new()
	small.size = Vector3(1.0, 2.0, 1.0)
	var wide := BoxMesh.new()
	wide.size = Vector3(2.0, 1.0, 3.0)
	var variants: Array[Mesh] = [small, wide]
	var spots: Array[Transform3D] = [
		Transform3D(Basis(Vector3.UP, 0.4).scaled(Vector3(1.4, 0.8, 0.7)), Vector3(0, 1, 0)),
		Transform3D(Basis(Vector3.RIGHT, 0.2).scaled(Vector3(0.6, 1.3, 1.2)), Vector3(12, 2, 0)),
		Transform3D(Basis(Vector3.UP, -0.7).scaled(Vector3(0.8, 1.1, 1.5)), Vector3(-13, 1, -4)),
	]
	var stage := Stage.new()
	var builder := StageBuilder.new(stage)
	var trees: Array[Transform3D] = [
		Transform3D(Basis(Vector3.UP, 0.6).scaled(Vector3(1.2, 0.8, 1.2)), Vector3(55, -0.25, 0)),
		Transform3D(Basis(Vector3.UP, -1.2).scaled(Vector3(0.8, 1.15, 0.8)), Vector3(-66, 0.75, 5)),
	]
	builder.tree_colliders = trees
	seed(9981)
	var expected_next := randi()
	seed(9981)
	GroundCover._colliders(world, variants, spots, "TestProps")
	builder._trunks(world)
	_check(randi() == expected_next, "scenery collision construction consumed global randomness")
	var prop_shapes := world.get_node("TestProps").find_children("*", "CollisionShape3D", true, false)
	_check(prop_shapes.size() == 3, "not every solid prop received one collision shape")
	# Independent expected variant sequence for the three fixture spots.
	var expected_variants := [wide, small, wide]
	for i in spots.size():
		var found := false
		for node in prop_shapes:
			var cs := node as CollisionShape3D
			if cs.position.is_equal_approx(spots[i].origin):
				found = true
				var hull := cs.shape as ConvexPolygonShape3D
				var local_points := GroundCover._solid_shape(expected_variants[i]).points
				_check(cs.basis.is_equal_approx(Basis.IDENTITY), "placed prop hull retains a decomposed scale/shear")
				_check(hull != null and hull.points.size() == local_points.size(), "collider chose a different variant than the visible scatter")
				if hull != null and hull.points.size() == local_points.size():
					for p in local_points.size():
						_check((cs.transform * hull.points[p]).is_equal_approx(spots[i] * local_points[p]), "prop hull changed the full drawn rotation/scale/shear")
				var body := cs.get_parent() as StaticBody3D
				_check(body != null and body.collision_layer == 1 and body.get_meta("surface") == Surfaces.DIRT, "prop collider is not solid world layer 1")
		_check(found, "prop collider changed rotation, scale or placement")
	var trunks := world.get_node("Trunks").find_children("*", "CollisionShape3D", true, false)
	_check(trunks.size() == trees.size(), "off-road trees were dropped from the collision set")
	for xf in trees:
		var found := false
		for node in trunks:
			var cs := node as CollisionShape3D
			if cs.transform.is_equal_approx(xf):
				found = true
				var hull := cs.shape as ConvexPolygonShape3D
				_check(hull != null and hull.points.size() == 24, "trunk should use the shared simple convex shape")
				var body := cs.get_parent() as StaticBody3D
				_check(body != null and body.collision_layer == 1, "trunk must be visible to car/tyre/camera queries")
		_check(found, "trunk lost its drawn foot position or nonuniform scale")
	# Hide all visual nodes: collision must not depend on render visibility.
	world.visible = false
	await physics_frame
	await physics_frame
	var space := world.get_world_3d().direct_space_state
	var targets: Array[Vector3] = []
	for xf in spots:
		targets.append(xf.origin)
	for xf in trees:
		targets.append(xf * Vector3(0.0, 1.0, 0.0))
	for target in targets:
		_check_queries(space, target)
	world.free()
	stage.free()
	if failures.is_empty():
		print("solid props: full tree coverage, cached hulls, visual transforms, RNG and layer-1 car/camera queries passed")
	else:
		for message in failures:
			push_error(message)
	quit(0 if failures.is_empty() else 1)


func _check_generated_trees() -> void:
	seed(1)
	var stage := Stage.new()
	stage.generate(450.0)
	var builder := StageBuilder.new(stage)
	var p := stage.points[stage.points.size() / 2]
	var d := stage.dirs[stage.dirs.size() / 2]
	p += Vector3(-d.z, 0.0, d.x) * 90.0
	var chunk := Vector2i(floori(p.x / Stage.CHUNK), floori(p.z / Stage.CHUNK))
	var data := builder.terrain_chunk(chunk)
	var trees: Array = data.trees
	var colliders: Array = data.colliders
	_check(not trees.is_empty(), "off-road generation fixture contains no trees")
	_check(trees == colliders, "generated visible trees and collision transforms must agree exactly")
	var outside_old_band := false
	for xf: Transform3D in trees:
		var loc := stage.locate(xf.origin)
		if absf(loc.offset) > stage.width_at(loc.along) + 30.0:
			outside_old_band = true
	_check(outside_old_band, "fixture did not exercise the formerly non-solid forest")
	stage.free()


func _check_asset_shapes() -> void:
	for path in ["res://assets/props/rock_moss_set_01/rock_moss_set_01.gltf", "res://assets/props/tree_stump_01/tree_stump_01.gltf"]:
		var meshes := GroundCover._meshes(path)
		_check(not meshes.is_empty(), "solid prop asset has no displayed meshes")
		for mesh in meshes:
			var shape := GroundCover._solid_shape(mesh)
			_check(shape == GroundCover._solid_shape(mesh), "prop hull cache did not reuse its shape")
			var points := shape.points
			_check(points.size() == 14, "solid prop hull must stay bounded to fourteen support points")
			var bounds := AABB(points[0], Vector3.ZERO)
			for point in points:
				_check(point.is_finite(), "prop hull contains nonfinite geometry")
				bounds = bounds.expand(point)
			var visual := mesh.get_aabb()
			_check(bounds.position.is_equal_approx(visual.position) and bounds.end.is_equal_approx(visual.end), "hull lost the displayed mesh's extrema")


func _check_queries(space: PhysicsDirectSpaceState3D, target: Vector3) -> void:
	var ray := PhysicsRayQueryParameters3D.create(target + Vector3(5, 0, 0), target - Vector3(5, 0, 0), 1)
	_check(not space.intersect_ray(ray).is_empty(), "layer-1 ray passed through solid scenery")
	ray.collision_mask = 2
	_check(space.intersect_ray(ray).is_empty(), "scenery unexpectedly occupies the car collision layer")
	var sphere := SphereShape3D.new()
	sphere.radius = ChaseCamera.WORLD_RADIUS
	var body := BoxShape3D.new()
	body.size = Vector3(1.6, 0.8, 3.5)
	for shape: Shape3D in [sphere, body]:
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape = shape
		query.collision_mask = 1
		query.transform = Transform3D(Basis.IDENTITY, target + Vector3(5, 0, 0))
		query.motion = Vector3(-10, 0, 0)
		var fractions := space.cast_motion(query)
		_check(fractions.size() == 2 and fractions[0] < 1.0, "car/camera sweep passed through solid scenery")


func _check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)
