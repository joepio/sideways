extends SceneTree
## Headless integration regression for native-resolution split-screen layout.
## Run: godot --headless --path . --script res://tests/view_resolution.gd
## Uses the real startup signal hookup and view/HUD construction, without a stage.

const FIXTURE_SOURCE := """
extends "res://main.gd"

func _new_stage() -> void:
	pass
"""

const WINDOW_SIZES := [
	Vector2i(1920, 1080),
	Vector2i(3840, 2160),
	Vector2i(2560, 1440), # Fractional canvas scale.
	Vector2i(3839, 2159), # Odd pixel boundaries and slightly unequal X/Y scale.
	Vector2i(3001, 1201), # Expand must fill a wider logical canvas.
	Vector2i(1201, 1601), # Expand must also fill a taller logical canvas.
	Vector2i(1920, 1080), # Returning to the original size must not accumulate scale.
]

var _failures := 0
var _case_name := "startup"


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if not _expect(DisplayServer.get_name() == "headless", "Run this test with --headless"):
		quit(1)
		return
	# Load main only after autoload names have been registered. Keep its real
	# _ready, _build_scene, _seat, _layout_views and _arrange_views. Skip only
	# stage generation; no terrain, cars or simulation are needed for layout.
	await process_frame
	var game_night := root.get_node("GameNight")
	game_night.set("launched_by_daemon", false)
	game_night.set_process(false)
	var fixture_script := GDScript.new()
	fixture_script.source_code = FIXTURE_SOURCE
	if not _expect(fixture_script.reload() == OK, "Could not compile main layout fixture"):
		quit(1)
		return
	var fixture: Node = fixture_script.new()
	fixture.process_mode = Node.PROCESS_MODE_DISABLED
	root.add_child(fixture)
	if not _expect(root.size_changed.is_connected(Callable(fixture, "_arrange_views")), "Startup did not connect window resizing"):
		fixture.free()
		quit(1)
		return
	_expect(root.content_scale_mode == Window.CONTENT_SCALE_MODE_CANVAS_ITEMS, "Fixture must use the game's canvas_items mode")
	_expect(root.content_scale_aspect == Window.CONTENT_SCALE_ASPECT_EXPAND, "Fixture must use the game's expand aspect")
	_expect(root.content_scale_size == Vector2i(1920, 1080), "Unexpected design resolution")
	root.content_scale_factor = 1.0
	var cases := 0
	for count in [1, 2, 4]:
		root.size = WINDOW_SIZES[0]
		var roster: Array = []
		for index in count:
			roster.append({"bot": true, "seat": index, "pad": -1})
		fixture.call("_seat", roster)
		await process_frame
		await process_frame
		var players: Array = fixture.get("players")
		var original_views: Array[int] = []
		var original_huds: Array[int] = []
		var baseline_huds: Array[Rect2] = []
		for player in players:
			original_views.append(player.view.get_instance_id())
			original_huds.append(player.hud.get_instance_id())
			baseline_huds.append(player.hud.get_rect())
		for window_size in WINDOW_SIZES:
			_case_name = "%d views at %s" % [count, window_size]
			# Deliberately do not call _arrange_views: the real size_changed
			# connection must resize existing SubViewports and preserve HUDs.
			root.size = window_size
			await process_frame
			await process_frame
			_expect(root.size == window_size, "Headless window did not accept the requested size")
			_check_layout(fixture, window_size, original_views, original_huds)
			if window_size in [Vector2i(1920, 1080), Vector2i(3840, 2160), Vector2i(2560, 1440)]:
				for index in count:
					var hud: Control = players[index].hud
					_expect(hud.get_rect().is_equal_approx(baseline_huds[index]), "Window resolution changed the logical HUD layout")
			if window_size in [Vector2i(1920, 1080), Vector2i(3840, 2160)]:
				# Known pixel counts independently catch the original fixed-1080p
				# render targets, even if every transformed rectangle looks right.
				var expected: Vector2i = {1: Vector2i(1920, 1080), 2: Vector2i(1920, 538), 4: Vector2i(958, 538)}[count]
				if window_size.x == 3840:
					expected *= 2
				for player in players:
					var viewport: SubViewport = player.view.get_child(0)
					_expect(viewport.size == expected, "Expected actual render target %s, got %s" % [expected, viewport.size])
			cases += 1
			if _failures > 0:
				fixture.free()
				quit(1)
				return
	fixture.free()
	print("view resolution: %d real window layouts passed; native pixels, resize signal, HUD scale, gaps and coverage" % cases)
	quit()


func _check_layout(fixture: Node, output_size: Vector2i, view_ids: Array[int], hud_ids: Array[int]) -> void:
	var players: Array = fixture.get("players")
	var views_root: Control = fixture.get("views_root")
	_expect(views_root.get_child_count() == players.size() * 2, "Reseating leaked an old view origin or HUD")
	var bounds: Array[Rect2i] = []
	var canvas_scale := root.get_stretch_transform().get_scale()
	for index in players.size():
		var container: SubViewportContainer = players[index].view
		var viewport := container.get_child(0) as SubViewport
		var hud: Control = players[index].hud
		_expect(container.get_instance_id() == view_ids[index], "Resize recreated a view")
		_expect(hud.get_instance_id() == hud_ids[index], "Resize recreated a HUD")
		if not _expect(viewport != null, "Actual SubViewport child is missing"):
			return
		_expect(container.stretch and container.stretch_shrink == 1, "Container reduces the render resolution")
		_expect(is_equal_approx(viewport.scaling_3d_scale, 1.0), "Native mode reduces internal 3D resolution")
		# Control.get_transform() omits the LOCAL position rounding applied by
		# Control::_update_canvas_item_transform when GUI pixel snapping is on.
		# Such hidden rounding breaks native mapping at fractional canvas scales.
		if root.is_snap_controls_to_pixels_enabled():
			_expect(_near(container.position, container.position.round(), 0.0001), "GUI pixel snapping rounds fractional logical placement before rendering")
		var transform := container.get_viewport_transform() * container.get_global_transform()
		_expect(transform.x.is_equal_approx(Vector2.RIGHT) and transform.y.is_equal_approx(Vector2.DOWN), "One viewport texel does not map to one physical pixel")
		var physical := transform * Rect2(Vector2.ZERO, container.size)
		_expect(_near(physical.position, physical.position.round(), 0.01), "View starts between physical pixels")
		_expect(_near(physical.end, physical.end.round(), 0.01), "View ends between physical pixels")
		_expect(_near(physical.size, Vector2(viewport.size), 0.01), "Rendered viewport %s differs from physical %s (container %.9f x %.9f)" % [viewport.size, physical.size, container.size.x, container.size.y])
		var pixels := Rect2i(Vector2i(physical.position.round()), Vector2i(physical.size.round()))
		_expect(Rect2i(Vector2i.ZERO, output_size).encloses(pixels), "View extends outside the output")
		bounds.append(pixels)
		# HUD stays in logical coordinates; only its sibling image compensates
		# for root stretching. Pixel rounding may move an image edge by 0.5 px.
		_expect(hud.scale.is_equal_approx(Vector2.ONE), "HUD inherited inverse rendering scale")
		var hud_transform := hud.get_viewport_transform() * hud.get_global_transform()
		var hud_physical := hud_transform * Rect2(Vector2.ZERO, hud.size)
		_expect(_near(physical.position, hud_physical.position, 0.51), "HUD origin is not aligned with its view")
		_expect(_near(physical.end, hud_physical.end, 0.51), "HUD edge is not aligned with its view")
	for a in bounds.size():
		for b in range(a + 1, bounds.size()):
			_expect(not bounds[a].intersects(bounds[b]), "Split-screen views overlap")
	_check_coverage(bounds, output_size, canvas_scale)


func _check_coverage(bounds: Array[Rect2i], output_size: Vector2i, canvas_scale: Vector2) -> void:
	if bounds.size() == 1:
		_expect(bounds[0] == Rect2i(Vector2i.ZERO, output_size), "Single view does not cover the output")
		return
	var bottom := bounds.size() - 1
	_expect(bounds[0].position == Vector2i.ZERO and bounds[bottom].end == output_size, "Outer screen corners are uncovered")
	var gap_y: int
	var gap_x := 0
	if bounds.size() == 2:
		_expect(bounds[0].size.x == output_size.x and bounds[1].size.x == output_size.x, "Two-player views do not span the screen width")
		gap_y = bounds[1].position.y - bounds[0].end.y
	else:
		_expect(bounds[1].position.y == 0 and bounds[2].position.x == 0, "Four-player outer edges are uncovered")
		_expect(bounds[1].end.x == output_size.x and bounds[2].end.y == output_size.y, "Four-player outer edges are cropped")
		_expect(bounds[0].size.y == bounds[1].size.y and bounds[2].size.y == bounds[3].size.y, "Split-screen row edges differ")
		_expect(bounds[0].size.x == bounds[2].size.x and bounds[1].size.x == bounds[3].size.x, "Split-screen column edges differ")
		_expect(bounds[1].position.x == bounds[3].position.x and bounds[2].position.y == bounds[3].position.y, "Split-screen gutters are not straight")
		gap_x = bounds[1].position.x - bounds[0].end.x
		gap_y = bounds[2].position.y - bounds[0].end.y
		_expect(gap_x > 0 and absf(gap_x - 4.0 * canvas_scale.x) <= 1.01, "Horizontal gutter is not the intended four logical pixels")
	_expect(gap_y > 0 and absf(gap_y - 4.0 * canvas_scale.y) <= 1.01, "Vertical gutter is not the intended four logical pixels")
	var covered := 0
	for rect in bounds:
		covered += rect.get_area()
	var gutters := gap_y * output_size.x + gap_x * output_size.y - gap_x * gap_y
	_expect(covered + gutters == output_size.x * output_size.y, "Output has uncovered pixels beyond the intended gutters")


func _near(a: Vector2, b: Vector2, tolerance: float) -> bool:
	return absf(a.x - b.x) <= tolerance and absf(a.y - b.y) <= tolerance


func _expect(condition: bool, message: String) -> bool:
	if not condition:
		_failures += 1
		push_error("%s: %s" % [_case_name, message])
	return condition
