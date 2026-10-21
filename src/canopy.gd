class_name Canopy
extends Node
## Forest shade for the whole stage. Real-time shadows reach 160 m and the
## thinned trees let a lot through, so the forest floor looked lit like a
## meadow. This draws a soft shadow blob for every tree (stretched away from
## the sun, as long as the tree is tall) into one top-down map, once per
## stage on the GPU, and the ground, road and grass shaders darken the sun
## and some of the sky light by it (canopy.gdshaderinc). Near the camera the
## darker of the map and the real shadow wins, so they never add up.

const TEXEL := 1.0 ## metres per pixel, grown for long stages
const MAX_SIDE := 4096
const DENSITY := 0.42 ## how much one tree's crown blocks

var _vp: SubViewport


static func build(parent: Node, spots: Array[Transform3D]) -> void:
	RenderingServer.global_shader_parameter_set("canopy_rect", Vector4.ZERO)
	if spots.is_empty() or DisplayServer.get_name() == "headless":
		return
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for xf in spots:
		var p := Vector2(xf.origin.x, xf.origin.z)
		lo = lo.min(p)
		hi = hi.max(p)
	lo -= Vector2(40, 40)
	hi += Vector2(40, 40)
	var texel := maxf(TEXEL, maxf(hi.x - lo.x, hi.y - lo.y) / MAX_SIDE)
	var size := Vector2i(ceili((hi.x - lo.x) / texel), ceili((hi.y - lo.y) / texel))
	var c := Canopy.new()
	c.name = "Canopy"
	parent.add_child(c)
	c._draw_map(spots, lo, texel, size)


func _draw_map(spots: Array[Transform3D], origin: Vector2, texel: float, size: Vector2i) -> void:
	_vp = SubViewport.new()
	_vp.size = size
	_vp.disable_3d = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	_vp.set_meta("bake", true)
	var bg := ColorRect.new()
	bg.color = Color.BLACK
	bg.size = Vector2(size)
	_vp.add_child(bg)
	# Shadow direction and length per metre of height, on flat ground.
	var sun := Look.sun_direction()
	var away := -Vector2(sun.x, sun.z).normalized()
	var reach := Vector2(sun.x, sun.z).length() / maxf(sun.y, 0.15)
	var quad := QuadMesh.new()
	quad.size = Vector2(1, 1)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.mesh = quad
	mm.instance_count = spots.size()
	for i in spots.size():
		var xf := spots[i]
		var s := xf.basis.get_scale()
		var height := 17.0 * s.y
		# Crown from about 3 m up to the top: its shadow starts that far
		# out and runs to the tip's shadow.
		var near := 3.0 * reach
		var far := height * reach
		var length := (far - near) + 4.5 * s.x
		var width := 4.2 * s.x
		var centre := Vector2(xf.origin.x, xf.origin.z) + away * (near + far) * 0.5
		var px := (centre - origin) / texel
		var t := Transform2D(away.angle(), Vector2(length, width) / texel, 0.0, px)
		mm.set_instance_transform_2d(i, t)
	var mmi := MultiMeshInstance2D.new()
	mmi.multimesh = mm
	mmi.texture = _blob()
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	mmi.material = mat
	mmi.modulate = Color(DENSITY, DENSITY, DENSITY)
	_vp.add_child(mmi)
	add_child(_vp)
	await RenderingServer.frame_post_draw
	var img := _vp.get_texture().get_image()
	_vp.queue_free()
	if img == null or img.is_empty():
		return
	img.convert(Image.FORMAT_L8)
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	RenderingServer.global_shader_parameter_set("canopy_map", tex)
	RenderingServer.global_shader_parameter_set("canopy_rect",
		Vector4(origin.x, origin.y, 1.0 / (size.x * texel), 1.0 / (size.y * texel)))


## A soft ellipse, densest a little towards the tree, as a cone's shadow is.
static func _blob() -> ImageTexture:
	var n := 64
	var img := Image.create_empty(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var u := (x + 0.5) / n * 2.0 - 1.0
			var v := (y + 0.5) / n * 2.0 - 1.0
			var d := sqrt(u * u + v * v)
			var a := clampf(1.0 - d, 0.0, 1.0)
			a = a * a * (3.0 - 2.0 * a) * lerpf(1.0, 0.7, (u + 1.0) * 0.5)
			img.set_pixel(x, y, Color(1, 1, 1, a))
	return ImageTexture.create_from_image(img)
