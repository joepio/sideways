extends SceneTree
## Real generated descriptors, texture payloads, contact queries and weather
## tables. No shader-source matching or duplicate terrain-generation oracle.

class GravelStage extends Stage:
	func _road_surfaces() -> void:
		pass

var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_check([Surfaces.GRAVEL, Surfaces.LOOSE, Surfaces.GRASS, Surfaces.DIRT, Surfaces.WATER] == [0, 1, 2, 3, 4], "original surface IDs changed")
	_check_weather()
	for stage_seed in [1, 17, 4242]:
		seed(stage_seed)
		var original := GravelStage.new()
		original.generate(2140.0)
		var expected_rng := randi()
		seed(stage_seed)
		var stage := Stage.new()
		stage.generate(2140.0)
		_check(randi() == expected_rng, "surface layout consumed global randomness")
		for property in ["points", "dirs", "widths", "curvature", "ledges", "ledge_wall", "ledge_drop", "rivers", "notes"]:
			_check(var_to_bytes(stage.get(property)) == var_to_bytes(original.get(property)), "surface layout changed existing geometry/data: " + property)
		_check_generated(stage)
		var saved := stage.road_surfaces.duplicate()
		stage._road_surfaces()
		_check(saved == stage.road_surfaces, "private descriptor generation is not repeatable")
		original.free()
		stage.free()
	_check_small_and_clear()
	_check_water_and_ai()
	if failures.is_empty():
		print("stage surfaces: deterministic sections, shared material/contact boundaries, wet grip, water override and AI plan passed")
	else:
		for message in failures:
			push_error(message)
	quit(0 if failures.is_empty() else 1)


func _check_weather() -> void:
	var authored := var_to_bytes(Surfaces.TABLE)
	for wet in [0.0, 1.0, 0.25, 0.0]:
		Surfaces.set_wetness(wet)
		for id in 5:
			_check(Surfaces.get_surface(id) == Surfaces.TABLE[id], "weather changed an original surface")
		_check(is_equal_approx(Surfaces.get_surface(Surfaces.ASPHALT).mu, lerpf(1.12, 0.86, wet)), "asphalt wet grip did not update/reset")
		_check(is_equal_approx(Surfaces.get_surface(Surfaces.MUD).mu, lerpf(0.70, 0.56, wet)), "mud wet grip did not update/reset")
		_check(Surfaces.get_surface(Surfaces.MUD).drag >= 200.0, "mud lost viscous resistance")
	_check(var_to_bytes(Surfaces.TABLE) == authored, "weather mutated shared authored coefficients")
	_check(Surfaces.get_surface(Surfaces.ASPHALT) == Surfaces.TABLE[Surfaces.ASPHALT], "dry weather retained stale asphalt values")
	_check(Surfaces.get_surface(Surfaces.MUD) == Surfaces.TABLE[Surfaces.MUD], "dry weather retained stale mud values")
	Surfaces.set_wetness(Look.wetness)


func _check_generated(stage: Stage) -> void:
	_check(stage.road_surfaces.size() == stage.points.size(), "descriptor does not span the complete road/runout")
	var counts := {}
	for surface in stage.road_surfaces:
		counts[surface] = int(counts.get(surface, 0)) + 1
	for surface in [Surfaces.GRAVEL, Surfaces.DIRT, Surfaces.MUD, Surfaces.ASPHALT]:
		_check(counts.get(surface, 0) > 0, "long stage omitted a required road type")
	_check(int(counts.get(Surfaces.GRAVEL, 0)) > stage.road_surfaces.size() * 0.65, "stage is no longer mostly gravel")
	_check(stage.road_surface_at(0.0) == Surfaces.GRAVEL and stage.road_surface_at(stage.length) == Surfaces.GRAVEL, "start or runout lost gravel")
	var builder := StageBuilder.new(stage)
	var texture: Texture2D = builder.road_material.get_shader_parameter("road_surface_map")
	var image := texture.get_image()
	_check(image != null and image.get_format() == Image.FORMAT_RGF and not image.has_mipmaps(), "material descriptor changed format or acquired mip blending")
	_check(image.get_width() == stage.road_surfaces.size() and image.get_height() == 1, "material descriptor dimensions differ")
	_check(builder.road_material.get_shader_parameter("road_surface_step") == Stage.STEP, "material uses a different along step")
	for row in stage.road_surfaces.size():
		var data := image.get_pixel(row, 0)
		_check(int(data.r) == stage.road_surfaces[row] and data.g == stage.widths[row], "actual texture payload differs from contact descriptor")
	var previous_end := 0.0
	for section in stage.surface_sections:
		var begin: float = section["from"]
		var end: float = section.to
		_check(begin >= previous_end + 40.0 and end - begin >= 40.0, "road types switch too frequently or overlap")
		_check(end < stage.finish, "non-gravel section entered the finish runout")
		previous_end = end
		for boundary in [begin, end]:
			# A metre-wide pair avoids asserting exact inverse coordinates on a
			# curved/wide ribbon. Both sides of every actual transition are tested.
			for delta in [-0.5, 0.5]:
				var along: float = boundary + delta
				var row := floori(along / Stage.STEP)
				var expected := int(image.get_pixel(row, 0).r)
				for side in [-0.8, 0.0, 0.8]:
					var d := stage.dir_at(along)
					var p: Vector3 = stage.point_at(along) + Vector3(-d.z, 0.0, d.x) * side
					var contact := stage.surface_near(p, -1)
					_check(contact.x == expected, "curved contact/material transition disagrees")
					_check(stage.surface_near(p, contact.y).x == expected, "hint changed a surface transition")
		var middle := (begin + end) * 0.5
		var d := stage.dir_at(middle)
		var right := Vector3(-d.z, 0.0, d.x)
		var centre := stage.point_at(middle)
		_check(stage.surface_at(centre + right * (stage.width_at(middle) - 0.3)) == Surfaces.LOOSE, "new road section replaced the loose shoulder")
		_check(stage.surface_at(centre + right * (stage.width_at(middle) + 1.5)) == Surfaces.GRASS, "new road section replaced the grass verge")
	print("stage surfaces sections: ", JSON.stringify(stage.surface_sections))


func _check_small_and_clear() -> void:
	var stage := Stage.new()
	stage.points.resize(100)
	stage.finish = 198.0
	stage._road_surfaces()
	_check(stage.surface_sections.is_empty() and stage.road_surfaces.count(Surfaces.GRAVEL) == 100, "small fixtures received mandatory surface sections")
	stage.road_surfaces.fill(Surfaces.MUD)
	stage._road_surfaces()
	_check(stage.road_surfaces.count(Surfaces.GRAVEL) == 100, "regeneration retained an earlier surface")
	stage.free()


func _check_water_and_ai() -> void:
	var stage := Stage.new()
	for i in 100:
		stage.points.append(Vector3(0, 0, -i * Stage.STEP))
		stage.dirs.append(Vector3.FORWARD)
		stage.widths.append(3.4)
		stage.curvature.append(0.03)
		stage.road_surfaces.append(Surfaces.GRAVEL)
	stage._index()
	var gravel := RallyAI.new(stage, 0.95)
	stage.road_surfaces.fill(Surfaces.ASPHALT)
	var asphalt := RallyAI.new(stage, 0.95)
	_check(gravel.plan == asphalt.plan, "new asphalt needlessly speeds up the existing AI")
	stage.road_surfaces.fill(Surfaces.MUD)
	var mud := RallyAI.new(stage, 0.95)
	_check(mud.plan[50] < gravel.plan[50], "AI plan ignored lower-grip mud")
	var road := Node3D.new()
	road.set_meta("road", true)
	var car := Car.new()
	car.setup("rally2")
	car.surface_at = stage.surface_near
	var p := Vector3(0, 0, -60)
	for surface in [Surfaces.ASPHALT, Surfaces.MUD]:
		stage.road_surfaces.fill(surface)
		_check(car._surface(car.wheels[0], road, p, 0.08) == surface, "road descriptor lost the strict water threshold")
		_check(car._surface(car.wheels[0], road, p, 0.0801) == Surfaces.WATER, "new road descriptor overrode a ford")
	car.free()
	road.free()
	stage.free()


func _check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)
