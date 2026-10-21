class_name CarModel
## The look of a car. Cars with a "model" in their spec use that glTF: the
## body is painted the player's colour, each wheel gets a knuckle that steers
## and rides the suspension (with the brake caliper on it) and a spinner that
## rolls, and the tyres are drawn with tyre.gdshader so they flatten under
## load. Without a model it falls back to a lofted placeholder built in code.

const BODY_SECTIONS := [
	# z (forward is -), half width, bottom y, top y, roundness
	[-2.02, 0.70, -0.08, 0.30, 0.55],
	[-1.90, 0.84, -0.14, 0.42, 0.45],
	[-1.55, 0.88, -0.16, 0.50, 0.35],
	[-1.00, 0.89, -0.16, 0.56, 0.30],
	[-0.40, 0.88, -0.16, 0.60, 0.30],
	[0.60, 0.88, -0.16, 0.62, 0.30],
	[1.30, 0.88, -0.14, 0.64, 0.32],
	[1.80, 0.84, -0.08, 0.66, 0.40],
	[1.98, 0.76, 0.00, 0.62, 0.50],
]
const CABIN_SECTIONS := [
	[-0.55, 0.78, 0.58, 0.62, 0.3],
	[-0.15, 0.74, 0.62, 1.02, 0.35],
	[0.70, 0.72, 0.62, 1.10, 0.35],
	[1.55, 0.72, 0.64, 1.04, 0.35],
	[1.90, 0.70, 0.64, 0.70, 0.4],
]


const CORNERS := ["FL", "FR", "RL", "RR"] ## in the order of Car.wheels


static func build(car: Car, color: Color) -> Node3D:
	if car.spec.has("model"):
		return _imported(car, color)
	return _placeholder(car, color)


## Collision for a model's body: a full-width box up to the waist and a
## narrower one for the cabin, so cars meet each other and the ground where
## they look like they do.
static func collision(car: Car) -> Array[CollisionShape3D]:
	var aabb := AABB(Vector3(-0.88, 0.0, -1.98), Vector3(1.76, 1.1, 3.95))
	if car.spec.has("model"):
		aabb = body_aabb(car)
	var shapes: Array[CollisionShape3D] = []
	var bottom := 0.06 # clear of the ground with the springs on the bump stops
	var waist := lerpf(aabb.position.y, aabb.end.y, 0.55)
	var top := aabb.end.y - 0.03
	var centre := aabb.get_center()
	for part in [[aabb.size.x * 0.97, bottom, waist, aabb.size.z * 0.97], [aabb.size.x * 0.76, waist, top, aabb.size.z * 0.5]]:
		var box := BoxShape3D.new()
		box.size = Vector3(part[0], part[2] - part[1], part[3])
		var cs := CollisionShape3D.new()
		cs.shape = box
		cs.position = Vector3(0.0, (part[1] + part[2]) * 0.5, centre.z)
		shapes.append(cs)
	return shapes


static var _aabbs := {}


## Where the rear number plate is, in car space: the model's plate surface,
## or the spec's "plate" AABB. Zero size when the car has none.
static func plate_rect(car: Car) -> AABB:
	var path: String = car.spec.model
	if not _plates.has(path) and not car.spec.has("plate"):
		var found := AABB()
		var scene: Node3D = load(path).instantiate()
		for n in scene.get_children():
			if n is MeshInstance3D and String(n.name).begins_with("body"):
				for i in n.mesh.get_surface_count():
					var mat: Material = n.mesh.surface_get_material(i)
					if mat and mat.resource_name.contains("Numberplate"):
						var v: PackedVector3Array = n.mesh.surface_get_arrays(i)[Mesh.ARRAY_VERTEX]
						var box := AABB(v[0], Vector3.ZERO)
						for p in v:
							if p.z > 1.0:
								box = box.expand(p)
						found = box
		scene.free()
		_plates[path] = found
	var r: AABB = car.spec.plate if car.spec.has("plate") else _plates[path]
	r.position.y += car.spec.get("ride", 0.0)
	return r


static var _plates := {}


## The body's bounds in car space, ride height included.
static func body_aabb(car: Car) -> AABB:
	var aabb := _body_aabb(car.spec.model)
	aabb.position.y += car.spec.get("ride", 0.0)
	return aabb


static func _body_aabb(path: String) -> AABB:
	if not _aabbs.has(path):
		var scene: Node3D = load(path).instantiate()
		var aabb := AABB()
		for n in scene.get_children():
			if n is MeshInstance3D and String(n.name).begins_with("body"):
				aabb = n.transform * n.mesh.get_aabb()
		scene.free()
		_aabbs[path] = aabb
	return _aabbs[path]


static func _imported(car: Car, color: Color) -> Node3D:
	var scene: Node3D = load(car.spec.model).instantiate()
	var root := Node3D.new()
	root.name = "Model"
	root.position.y = car.spec.get("ride", 0.0)
	car.add_child(root)
	var parts := {}
	for n in scene.get_children():
		parts[String(n.name)] = n
	for key in parts:
		if key.begins_with("body"):
			var body: MeshInstance3D = parts[key]
			body.owner = null
			scene.remove_child(body)
			root.add_child(body)
			_paint(body, color)
	for i in car.wheels.size():
		var w: Car.Wheel = car.wheels[i]
		var wheel := _part(parts, "wheel_" + CORNERS[i])
		var caliper := _part(parts, "caliper_" + CORNERS[i])
		var knuckle := Node3D.new()
		knuckle.name = "Wheel" + CORNERS[i]
		car.add_child(knuckle)
		var spinner := Node3D.new()
		knuckle.add_child(spinner)
		w.node = knuckle
		w.spinner = spinner
		if wheel == null:
			continue
		# Drawn at the spec's size, so the tread meets the ground where the
		# suspension finds it (the MV6's rears are a touch bigger in the model).
		var k: float = w.radius / (wheel.mesh.get_aabb().size.y * 0.5)
		wheel.owner = null
		scene.remove_child(wheel)
		wheel.transform = Transform3D(Basis.from_scale(Vector3.ONE * k), Vector3.ZERO)
		spinner.add_child(wheel)
		_tyres(wheel)
		w.tyres.append(wheel)
		if caliper:
			caliper.owner = null
			scene.remove_child(caliper)
			caliper.transform = Transform3D(Basis.from_scale(Vector3.ONE * k), Vector3.ZERO)
			knuckle.add_child(caliper)
	scene.free()
	return root


static func _part(parts: Dictionary, prefix: String) -> MeshInstance3D:
	for key in parts:
		if key == prefix or key.begins_with(prefix + "_"):
			return parts[key]
	return null


static func _paint(body: MeshInstance3D, color: Color) -> void:
	for i in body.mesh.get_surface_count():
		var mat := body.mesh.surface_get_material(i) as StandardMaterial3D
		if mat == null or not (mat.resource_name.contains("Bodymat") or mat.resource_name.contains("Paint")):
			continue
		var paint: StandardMaterial3D = mat.duplicate()
		paint.albedo_color = color
		paint.metallic = 0.35
		paint.roughness = 0.3
		paint.clearcoat_enabled = true
		paint.clearcoat = 0.7
		paint.clearcoat_roughness = 0.15
		body.set_surface_override_material(i, paint)


## The tyre surfaces swap to tyre.gdshader, keeping their textures.
static func _tyres(wheel: MeshInstance3D) -> void:
	for i in wheel.mesh.get_surface_count():
		var mat := wheel.mesh.surface_get_material(i) as StandardMaterial3D
		if mat == null or not mat.resource_name.contains("Tire"):
			continue
		var sm := ShaderMaterial.new()
		sm.shader = preload("res://src/shaders/tyre.gdshader")
		sm.set_shader_parameter("albedo", mat.albedo_color)
		if mat.albedo_texture:
			sm.set_shader_parameter("albedo_tex", mat.albedo_texture)
		if mat.normal_enabled and mat.normal_texture:
			sm.set_shader_parameter("normal_tex", mat.normal_texture)
			sm.set_shader_parameter("use_normal", true)
		var mr: Texture2D = mat.roughness_texture if mat.roughness_texture else mat.metallic_texture
		if mr:
			sm.set_shader_parameter("mr_tex", mr)
			sm.set_shader_parameter("roughness", maxf(mat.roughness, 0.5))
			sm.set_shader_parameter("metallic", mat.metallic)
		else:
			sm.set_shader_parameter("roughness", 0.88)
		wheel.set_surface_override_material(i, sm)


static func _placeholder(car: Car, color: Color) -> Node3D:
	var root := Node3D.new()
	root.name = "Model"
	var paint := StandardMaterial3D.new()
	paint.albedo_color = color
	paint.metallic = 0.25
	paint.roughness = 0.32
	paint.clearcoat_enabled = true
	paint.clearcoat = 0.6
	var glass := StandardMaterial3D.new()
	glass.albedo_color = Color(0.05, 0.06, 0.07)
	glass.metallic = 0.8
	glass.roughness = 0.05
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.06, 0.06, 0.06)
	dark.roughness = 0.7
	var body := MeshInstance3D.new()
	body.mesh = _loft(BODY_SECTIONS, paint)
	root.add_child(body)
	var cabin := MeshInstance3D.new()
	cabin.mesh = _loft(CABIN_SECTIONS, glass)
	root.add_child(cabin)
	# Roof panel over the glasshouse so it reads as a car, not a bubble.
	var roof := MeshInstance3D.new()
	var rb := BoxMesh.new()
	rb.size = Vector3(1.30, 0.04, 1.55)
	rb.material = paint
	roof.mesh = rb
	roof.position = Vector3(0, 1.09, 0.72)
	root.add_child(roof)
	# Wheel arches, bumpers, mud flaps.
	for z in [-1.25, 1.25]:
		for x in [-0.86, 0.86]:
			var arch := MeshInstance3D.new()
			var cyl := CylinderMesh.new()
			cyl.top_radius = 0.42
			cyl.bottom_radius = 0.42
			cyl.height = 0.12
			cyl.material = dark
			arch.mesh = cyl
			arch.rotation.z = PI / 2
			arch.position = Vector3(x, 0.02, z)
			root.add_child(arch)
	var lights := StandardMaterial3D.new()
	lights.albedo_color = Color(1.0, 0.97, 0.88)
	lights.emission_enabled = true
	lights.emission = Color(1.0, 0.95, 0.8)
	lights.emission_energy_multiplier = 0.6
	for x in [-0.55, 0.55]:
		var l := MeshInstance3D.new()
		var lm := BoxMesh.new()
		lm.size = Vector3(0.32, 0.10, 0.04)
		lm.material = lights
		l.mesh = lm
		l.position = Vector3(x, 0.26, -1.96)
		root.add_child(l)
		var tail := MeshInstance3D.new()
		var tm := BoxMesh.new()
		tm.size = Vector3(0.30, 0.10, 0.04)
		var red := StandardMaterial3D.new()
		red.albedo_color = Color(0.5, 0.02, 0.02)
		red.emission_enabled = true
		red.emission = Color(0.6, 0.0, 0.0)
		tm.material = red
		tail.mesh = tm
		tail.position = Vector3(x, 0.40, 1.97)
		root.add_child(tail)
	var wing := MeshInstance3D.new()
	var wm := BoxMesh.new()
	wm.size = Vector3(1.30, 0.04, 0.30)
	wm.material = paint
	wing.mesh = wm
	wing.position = Vector3(0, 1.10, 1.85)
	root.add_child(wing)
	car.add_child(root)
	# Wheels.
	var tyre_mat := ShaderMaterial.new()
	tyre_mat.shader = load("res://src/shaders/tyre.gdshader")
	var rim_mat := StandardMaterial3D.new()
	rim_mat.albedo_color = Color(0.85, 0.85, 0.82)
	rim_mat.metallic = 0.6
	rim_mat.roughness = 0.35
	for w in car.wheels:
		var hub := Node3D.new()
		var tyre := MeshInstance3D.new()
		var tm2 := CylinderMesh.new()
		tm2.top_radius = w.radius
		tm2.bottom_radius = w.radius
		tm2.height = 0.22
		tm2.radial_segments = 40
		tm2.rings = 3
		tm2.material = tyre_mat
		tyre.mesh = tm2
		tyre.rotation.z = PI / 2
		hub.add_child(tyre)
		w.tyres.append(tyre)
		var rim := MeshInstance3D.new()
		var rm := CylinderMesh.new()
		rm.top_radius = w.radius * 0.66
		rm.bottom_radius = w.radius * 0.66
		rm.height = 0.23
		rm.radial_segments = 6
		rm.material = rim_mat
		rim.mesh = rm
		rim.rotation.z = PI / 2
		hub.add_child(rim)
		car.add_child(hub)
		w.node = hub
	return root


static func _loft(sections: Array, mat: Material) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(mat)
	var ring := 18
	var rings: Array[PackedVector3Array] = []
	for s in sections:
		var pts := PackedVector3Array()
		var hw: float = s[1]
		var lo: float = s[2]
		var hi: float = s[3]
		var r: float = s[4]
		for i in ring:
			var a := TAU * i / ring
			# Superellipse cross-section: boxy with rounded corners.
			var c := cos(a)
			var sn := sin(a)
			var e := 2.0 / (1.0 + r * 6.0) + 0.25
			var x := signf(c) * pow(absf(c), e) * hw
			var y := signf(sn) * pow(absf(sn), e)
			pts.append(Vector3(x, lerpf(lo, hi, y * 0.5 + 0.5), s[0]))
		rings.append(pts)
	for k in rings.size() - 1:
		for i in ring:
			var a := rings[k][i]
			var b := rings[k][(i + 1) % ring]
			var c := rings[k + 1][i]
			var d := rings[k + 1][(i + 1) % ring]
			st.add_vertex(a)
			st.add_vertex(c)
			st.add_vertex(b)
			st.add_vertex(b)
			st.add_vertex(c)
			st.add_vertex(d)
	# Caps.
	for k in [0, rings.size() - 1]:
		var centre := Vector3.ZERO
		for p in rings[k]:
			centre += p
		centre /= ring
		for i in ring:
			var a := rings[k][i]
			var b := rings[k][(i + 1) % ring]
			if k == 0:
				st.add_vertex(centre)
				st.add_vertex(a)
				st.add_vertex(b)
			else:
				st.add_vertex(centre)
				st.add_vertex(b)
				st.add_vertex(a)
	st.generate_normals()
	return st.commit()
