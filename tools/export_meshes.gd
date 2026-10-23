extends SceneTree
## Writes Godot meshes as plain .kmesh files for the Kern renderer:
##   "KMSH" u32 surfaces, then per surface: u32 name length, name (material
##   resource name), u32 vertex count, u32 index count, positions f32x3,
##   normals f32x3, uvs f32x2, indices u32. Little-endian.
##   godot --headless --path . --script res://tools/export_meshes.gd -- --out engine/assets

func _initialize() -> void:
	var out := "res://engine/assets"
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--out" and i + 1 < args.size():
			out = args[i + 1]
	DirAccess.make_dir_recursive_absolute(out)
	var sources := {}
	for v in ["a", "b", "c"]:
		for lod in ["near", "mid"]:
			sources["fir_%s_%s" % [v, lod]] = "res://assets/trees/fir_%s_%s.res" % [v, lod]
	for name in sources:
		var mesh: Mesh = load(sources[name])
		_write(mesh, out.path_join(name + ".kmesh"))
	for prop in ["fern_02", "rock_moss_set_01", "tree_stump_01"]:
		var scene: Node = load("res://assets/props/%s/%s.gltf" % [prop, prop]).instantiate()
		for n in scene.find_children("*", "MeshInstance3D", true, false):
			_write((n as MeshInstance3D).mesh, out.path_join("%s.kmesh" % prop))
			break
		scene.free()
	print("export: done")
	quit()


func _write(mesh: Mesh, path: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer("KMSH".to_ascii_buffer())
	f.store_32(mesh.get_surface_count())
	var tris := 0
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var mat := mesh.surface_get_material(s)
		var mname := mat.resource_name if mat else ""
		if mname == "" and mat is BaseMaterial3D and (mat as BaseMaterial3D).albedo_texture:
			mname = (mat as BaseMaterial3D).albedo_texture.resource_path.get_file()
		var nb := mname.to_utf8_buffer()
		f.store_32(nb.size())
		f.store_buffer(nb)
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var nrm: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		if idx.is_empty():
			for k in v.size():
				idx.append(k)
		f.store_32(v.size())
		f.store_32(idx.size())
		for p in v:
			f.store_float(p.x); f.store_float(p.y); f.store_float(p.z)
		for k in v.size():
			var n: Vector3 = nrm[k] if k < nrm.size() else Vector3.UP
			f.store_float(n.x); f.store_float(n.y); f.store_float(n.z)
		for k in v.size():
			var t: Vector2 = uv[k] if k < uv.size() else Vector2.ZERO
			f.store_float(t.x); f.store_float(t.y)
		for k in idx:
			f.store_32(k)
		tris += idx.size() / 3
		print("  %s surface %d '%s': %d verts, %d tris" % [path.get_file(), s, mname, v.size(), idx.size() / 3])
	f.close()
