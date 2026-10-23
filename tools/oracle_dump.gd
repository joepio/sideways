extends SceneTree
## Oracle for the Rust port: dumps what the Godot build computes, so the Rust
## side can be checked number for number.
##   godot --headless --path . --script res://tools/oracle_dump.gd -- --seed 1 --km 2 --out /tmp/oracle.json

func _initialize() -> void:
	var seed_value := 1
	var km := 2.0
	var out := "user://oracle.json"
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		var next: String = args[i + 1] if i + 1 < args.size() else ""
		match args[i]:
			"--seed": seed_value = int(next)
			"--km": km = float(next)
			"--out": out = next
	var o := {}

	# Global RNG.
	seed(12345)
	var r := []
	for i in 4:
		r.append(randi())
	for i in 4:
		r.append(randf())
	r.append(randf_range(20.0, 50.0))
	r.append(randi_range(60, 150))
	r.append(randi_range(-3, 7))
	o["rng"] = r

	# hash() of the arrays the game uses as seeds.
	o["hash"] = [hash([123, 4, -5]), hash([7, 9, "road surfaces"]), hash([4000000000, -1, 2]), hash(17), hash(-2)]
	var g := RandomNumberGenerator.new()
	g.seed = hash([123, 4, -5])
	o["rng_obj"] = [g.randf(), g.randf_range(-0.6, 0.6), g.randi()]

	# Noise.
	var n := FastNoiseLite.new()
	n.seed = 987654321
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = 1.0 / 420.0
	n.fractal_octaves = 3
	var d := FastNoiseLite.new()
	d.seed = 42
	d.frequency = 1.0 / 70.0
	d.fractal_octaves = 2
	var w := FastNoiseLite.new()
	w.seed = 11
	w.frequency = 1.0 / 18.0
	var ns := []
	for p in [Vector2(0, 0), Vector2(13.5, -800.25), Vector2(-1234.0, 567.0), Vector2(5000.5, 4999.5)]:
		ns.append([n.get_noise_2d(p.x, p.y), d.get_noise_2d(p.x, p.y), w.get_noise_1d(p.x), d.get_noise_1d(p.y)])
	o["noise"] = ns

	# A stage, the way main.gd makes one for --sim: weather draw, then the layout.
	seed(seed_value)
	o["weather_draw"] = randi() % 4
	var stage := Stage.new()
	stage.generate(km * 1000.0 + Stage.RUNOUT)
	o["noise_seeds"] = [stage._noise.seed, stage._detail.seed]
	o["next_randf"] = randf()
	var pts := []
	for p in stage.points:
		pts.append([p.x, p.y, p.z])
	o["points"] = pts
	o["widths"] = Array(stage.widths)
	o["curvature"] = Array(stage.curvature)
	o["ledges"] = Array(stage.ledges)
	o["ledge_wall"] = Array(stage.ledge_wall)
	o["ledge_drop"] = Array(stage.ledge_drop)
	o["road_surfaces"] = Array(stage.road_surfaces)
	var rivers := []
	for rv in stage.rivers:
		var rp := []
		for q in rv.pts:
			rp.append([q.x, q.y])
		rivers.append({"pts": rp, "levels": Array(rv.levels), "wet": Array(rv.wet), "half": rv.half, "depth": rv.depth, "cross": rv.cross, "ford": rv.ford})
	o["rivers"] = rivers
	o["notes"] = stage.notes
	o["length"] = stage.length
	o["finish"] = stage.finish
	# Heights and surfaces at points around the road.
	var hq := []
	for i in range(0, stage.points.size(), 37):
		var p := stage.points[i]
		var right := Vector3(-stage.dirs[i].z, 0.0, stage.dirs[i].x)
		for off in [0.0, 2.0, -3.9, 5.5, 12.0, -30.0, 80.0]:
			var q: Vector3 = p + right * float(off) + Vector3(0.3, 0.0, -0.7)
			hq.append([q.x, q.z, stage.height(q.x, q.z), stage.surface_at(Vector3(q.x, 0.0, q.z)), _finite(stage.water_level(q.x, q.z)), stage.nearest_index(q.x, q.z)])
	o["heights"] = hq

	# Terrain chunks: heights and solid trees.
	var builder := StageBuilder.new(stage)
	var list := builder.chunks()
	o["chunk_count"] = list.size()
	var chunks := []
	for ci in [0, list.size() / 3, list.size() / 2, list.size() - 1]:
		var c: Vector2i = list[ci]
		var data := builder.terrain_chunk(c)
		var trees := []
		for xf in data.colliders:
			trees.append([xf.origin.x, xf.origin.y, xf.origin.z, xf.basis.get_scale().x, xf.basis.get_scale().y])
		chunks.append({"c": [c.x, c.y], "hs": Array(data.hs), "trees": trees})
	o["chunks"] = chunks
	var rd := builder.road()
	var faces: PackedVector3Array = rd.faces
	var fsum := Vector3.ZERO
	for f in faces:
		fsum += f
	o["road_faces"] = [faces.size(), fsum.x, fsum.y, fsum.z, faces[0].x, faces[0].y, faces[0].z, faces[faces.size() - 1].y]

	# Collision boxes of the grid cars (from their glTF bodies).
	var cars := {}
	for id in CarSpec.GRID:
		var car := Car.new()
		car.setup(id)
		var boxes := []
		for cs in CarModel.collision(car):
			var b: BoxShape3D = cs.shape
			boxes.append([b.size.x, b.size.y, b.size.z, cs.position.x, cs.position.y, cs.position.z])
			cs.free()
		cars[id] = boxes
		car.free()
	o["car_boxes"] = cars

	var f := FileAccess.open(out, FileAccess.WRITE)
	f.store_string(JSON.stringify(o, "", true, true))
	f.close()
	print("oracle: wrote ", out)
	quit(0)


## JSON has no infinity: -INF (no water) becomes -1e30.
func _finite(x: float) -> float:
	return x if is_finite(x) else (-1e30 if x < 0.0 else 1e30)
