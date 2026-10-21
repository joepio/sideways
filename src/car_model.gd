class_name CarModel
## Placeholder bodywork built in code, until the real models are imported:
## a lofted hatchback body, glasshouse, lights and four wheels. The body
## colour is the player's colour.

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


static func build(car: Car, color: Color) -> Node3D:
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
