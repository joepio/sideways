class_name Props
## Stage furniture: start and finish gantries, marker boards.


static func start_finish(parent: Node3D, stage: Stage) -> void:
	_gantry(parent, stage, 4.0, Color(0.85, 0.12, 0.1))
	_gantry(parent, stage, stage.finish, Color(0.1, 0.1, 0.1), true)


static func _gantry(parent: Node3D, stage: Stage, along: float, color: Color, chequered := false) -> void:
	var p := stage.point_at(along)
	var d := stage.dir_at(along)
	var right := Vector3(-d.z, 0.0, d.x)
	var w := stage.width_at(along) + 1.6
	var root := Node3D.new()
	parent.add_child(root)
	var pole_mat := StandardMaterial3D.new()
	pole_mat.albedo_color = Color(0.85, 0.85, 0.85)
	pole_mat.metallic = 0.5
	pole_mat.roughness = 0.4
	for side in [-1.0, 1.0]:
		var pole := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.09
		cyl.bottom_radius = 0.09
		cyl.height = 5.2
		cyl.material = pole_mat
		pole.mesh = cyl
		var base: Vector3 = p + right * w * side
		base.y = stage.height(base.x, base.z)
		pole.position = base + Vector3.UP * 2.6
		root.add_child(pole)
	var banner := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(w * 2.0, 0.9, 0.06)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.7
	if chequered:
		var img := Image.create(16, 2, false, Image.FORMAT_RGB8)
		for x in 16:
			for y in 2:
				img.set_pixel(x, y, Color.WHITE if (x + y) % 2 == 0 else Color(0.05, 0.05, 0.05))
		mat.albedo_texture = ImageTexture.create_from_image(img)
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		mat.albedo_color = Color.WHITE
	box.material = mat
	banner.mesh = box
	banner.position = Vector3(p.x, p.y + 4.8, p.z)
	banner.basis = Basis.looking_at(d, Vector3.UP)
	root.add_child(banner)
