class_name DoorSticker
extends Node3D
## The driver on both doors: their GameNight face in a ring of their colour
## and their name in heavy italic, on a white sticker; and the first six
## letters of their name on the rear number plate. The art is drawn once in a
## small 2D viewport and copied to a texture. The door stickers are decals
## (each car's body sits on its own render layer so a decal only ever lands
## on its own car); the plate is a quad laid over the model's own plate.

const ART := Vector2i(640, 220)
const WIDTH := 1.15 ## metres along the door

static var _faces = preload("res://addons/gamenight/face.gd").new()
static var _font: Font

var _decals: Array[Decal] = []
var _plate: MeshInstance3D


static func attach(car: Car, player: Dictionary, slot: int) -> void:
	var model := car.get_node_or_null("Model")
	if model == null or not car.spec.has("model"):
		return
	var bit := 1 << (10 + slot % 10)
	for n in model.get_children():
		if n is MeshInstance3D:
			n.layers = 1 | bit
	var aabb := CarModel.body_aabb(car)
	var sticker := DoorSticker.new()
	sticker.name = "DoorSticker"
	car.add_child(sticker)
	var height := WIDTH * ART.y / ART.x
	# Below the windows, between the wheel arches.
	var y := lerpf(aabb.position.y, aabb.end.y, 0.33)
	for side in [-1.0, 1.0]:
		var d := Decal.new()
		d.size = Vector3(WIDTH, 0.7, height)
		d.cull_mask = bit
		d.normal_fade = 0.4
		d.upper_fade = 0.0
		d.lower_fade = 0.0
		d.distance_fade_enabled = true
		d.distance_fade_begin = 45.0
		d.distance_fade_length = 10.0
		# Projects inward along -Y; X runs to the front seen from that side,
		# Z runs down, so the text reads left to right on both doors.
		var out := Vector3(side, 0.0, 0.0)
		var along := Vector3(0.0, 0.0, -side)
		d.basis = Basis(along, out, along.cross(out))
		d.position = Vector3(side * (aabb.size.x * 0.5 - 0.1), y, aabb.get_center().z + 0.05)
		d.visible = false
		sticker.add_child(d)
		sticker._decals.append(d)
	var plate := CarModel.plate_rect(car)
	if plate.size.x > 0.0:
		var q := MeshInstance3D.new()
		var qm := QuadMesh.new()
		qm.size = Vector2(plate.size.x, plate.size.y)
		q.mesh = qm
		q.position = Vector3(plate.get_center().x, plate.get_center().y, plate.end.z + 0.004)
		q.visible = false
		q.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		sticker.add_child(q)
		sticker._plate = q
	sticker._paint(player)


func _paint(player: Dictionary) -> void:
	var art := Art.new()
	art.player = player
	var tex := await _bake(art, ART, true)
	if tex == null:
		return # headless: nothing was drawn
	for d in _decals:
		d.texture_albedo = tex
		d.visible = true
	if _plate:
		var size := Vector2i(512, maxi(64, roundi(512.0 * _plate.mesh.size.y / _plate.mesh.size.x)))
		var pa := PlateArt.new()
		pa.text = str(player.get("name", "")).to_upper().replace(" ", "").left(6)
		var ptex := await _bake(pa, size, false)
		if ptex == null:
			return
		var m := StandardMaterial3D.new()
		m.albedo_texture = ptex
		m.roughness = 0.5
		m.metallic = 0.2
		_plate.material_override = m
		_plate.visible = true


## Draws `art` once at `size` and returns it as a mipmapped texture.
func _bake(art: Control, size: Vector2i, transparent: bool) -> ImageTexture:
	var vp := SubViewport.new()
	vp.size = size
	vp.transparent_bg = transparent
	vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.set_meta("bake", true)
	art.size = Vector2(size)
	vp.add_child(art)
	add_child(vp)
	# Two frames: on the first, new glyphs are not in the font's texture yet
	# and come out as solid boxes.
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image() if is_inside_tree() else null
	vp.queue_free()
	if img == null or img.is_empty():
		return null
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


## A Finnish-style plate: white, thin black border, the blue EU band, and
## big upright letters stretched to fill the plate like a real registration.
## The letters are filled from the font's outlines rather than its glyph
## atlas: big atlas glyphs come out as solid boxes on some drivers.
class PlateArt extends Control:
	var text: String

	func _draw() -> void:
		var font: Font = load("res://assets/fonts/Barlow-SemiBold.ttf")
		var ink := Color(0.05, 0.05, 0.06)
		var paper := Color(0.95, 0.95, 0.93)
		var blue_ := Color(0.1, 0.25, 0.65)
		draw_rect(Rect2(Vector2.ZERO, size), ink)
		draw_rect(Rect2(Vector2(5, 5), size - Vector2(10, 10)), paper)
		var blue := Rect2(Vector2(5, 5), Vector2(size.y * 0.3, size.y - 10))
		draw_rect(blue, blue_)
		var fin := size.y * 0.2
		_outline_text(font, "FIN", Vector2(blue.position.x + blue.size.x * 0.12, blue.end.y - size.y * 0.1), fin, blue.size.x * 0.76, paper, blue_)
		var left := blue.end.x + size.y * 0.1
		var room := size.x - left - size.y * 0.12
		# Capitals about 70% of the plate's height, widened or narrowed to
		# fill the space whatever the name's length.
		var fs := size.y * 0.97
		_outline_text(font, text, Vector2(left, size.y * 0.5 + fs * 0.35), fs, room, ink, paper)

	## Fills `str_` from the font's outlines, its baseline starting at `at`,
	## scaled across to `width` (kept between 0.7 and 1.25 of natural width
	## and centred). Holes (the inside of an O) are painted in `back`.
	func _outline_text(font: Font, str_: String, at: Vector2, fs: float, width: float, color: Color, back: Color) -> void:
		var ts := TextServerManager.get_primary_interface()
		var rid: RID = font.get_rids()[0]
		const BASE := 64
		var k := fs / BASE
		var glyphs: Array = []
		var w := 0.0
		for ch in str_:
			var g := ts.font_get_glyph_index(rid, BASE, ch.unicode_at(0), 0)
			glyphs.append([g, w])
			w += ts.font_get_glyph_advance(rid, BASE, g).x
		var stretch := clampf(width / maxf(w * k, 1.0), 0.7, 1.25)
		var x0 := at.x + (width - w * k * stretch) * 0.5
		for gl in glyphs:
			var d: Dictionary = ts.font_get_glyph_contours(rid, BASE, gl[0])
			if d.is_empty():
				continue
			var polys := _contours(d)
			var outer_sign := 0.0
			var big := 0.0
			for poly in polys:
				var area := _area(poly)
				if absf(area) > big:
					big = absf(area)
					outer_sign = signf(area)
			for pass_ in 2:
				for poly in polys:
					var outer := signf(_area(poly)) == outer_sign
					if outer != (pass_ == 0):
						continue
					var pts := PackedVector2Array()
					for p in poly:
						pts.append(Vector2(x0 + (gl[1] + p.x) * k * stretch, at.y + p.y * k))
					if Geometry2D.triangulate_polygon(pts).is_empty():
						continue
					draw_colored_polygon(pts, color if outer else back)

	## The glyph's closed outlines with its curves flattened.
	static func _contours(d: Dictionary) -> Array:
		var points: PackedVector3Array = d.points
		var ends: PackedInt32Array = d.contours
		var out: Array = []
		var start := 0
		for e in ends:
			var raw: Array[Vector3] = []
			for i in range(start, e + 1):
				raw.append(points[i])
			start = e + 1
			if raw.size() < 3:
				continue
			# Start on an on-curve point (or the midpoint of two off ones).
			var first := -1
			for i in raw.size():
				if int(raw[i].z) == 1:
					first = i
					break
			if first < 0:
				raw.insert(0, Vector3((raw[0].x + raw[-1].x) * 0.5, (raw[0].y + raw[-1].y) * 0.5, 1))
				first = 0
			var ring: Array[Vector3] = []
			for i in raw.size():
				ring.append(raw[(first + i) % raw.size()])
			ring.append(ring[0])
			var poly := PackedVector2Array([Vector2(ring[0].x, ring[0].y)])
			var ctrl: Variant = null
			for i in range(1, ring.size()):
				var p := Vector2(ring[i].x, ring[i].y)
				if int(ring[i].z) == 1:
					if ctrl == null:
						poly.append(p)
					else:
						_conic(poly, poly[-1], ctrl, p)
						ctrl = null
				else:
					if ctrl != null:
						var mid: Vector2 = (ctrl + p) * 0.5
						_conic(poly, poly[-1], ctrl, mid)
					ctrl = p
			if poly.size() > 1 and poly[0].is_equal_approx(poly[-1]):
				poly.remove_at(poly.size() - 1)
			out.append(poly)
		return out

	static func _conic(poly: PackedVector2Array, a: Vector2, c: Vector2, b: Vector2) -> void:
		for s in range(1, 7):
			var t := s / 6.0
			poly.append(a.lerp(c, t).lerp(c.lerp(b, t), t))

	static func _area(poly: PackedVector2Array) -> float:
		var a := 0.0
		for i in poly.size():
			var p := poly[i]
			var q := poly[(i + 1) % poly.size()]
			a += p.x * q.y - q.x * p.y
		return a * 0.5


class Art extends Control:
	var player: Dictionary

	func _draw() -> void:
		if DoorSticker._font == null:
			DoorSticker._font = load("res://assets/fonts/BarlowCondensed-ExtraBoldItalic.ttf")
		var font := DoorSticker._font
		var color: Color = player.get("color", Color.WHITE)
		var ink := Color(0.07, 0.07, 0.09)
		var r := 100.0
		var face := Vector2(r + 8.0, size.y * 0.5)
		# The name plate: a slanted white tag with a dark edge and a stripe in
		# the player's colour, tucked under the face.
		var top := face.y - 62.0
		var bottom := face.y + 62.0
		var x0 := face.x
		var x1 := size.x - 12.0
		var plate := PackedVector2Array([Vector2(x0, top), Vector2(x1, top), Vector2(x1 - 26.0, bottom), Vector2(x0, bottom)])
		var edge := PackedVector2Array([Vector2(x0, top - 7), Vector2(x1 + 9, top - 7), Vector2(x1 - 22.0, bottom + 7), Vector2(x0, bottom + 7)])
		draw_colored_polygon(edge, ink)
		draw_colored_polygon(plate, Color.WHITE)
		var stripe := PackedVector2Array([Vector2(x0, bottom - 22), Vector2(x1 - 21.5, bottom - 22), Vector2(x1 - 26.0, bottom), Vector2(x0, bottom)])
		draw_colored_polygon(stripe, color)
		# The face in a white and colour ring.
		draw_circle(face, r, ink)
		draw_circle(face, r - 7.0, Color.WHITE)
		draw_circle(face, r - 15.0, color)
		var profile: Dictionary = player.get("profile", {})
		DoorSticker._faces.draw_face(self, profile, face, r - 23.0)
		# The name, as large as fits.
		var name_ := str(player.get("name", "")).to_upper()
		var left := face.x + r + 14.0
		var room := x1 - 40.0 - left
		var fs := 92
		while fs > 30 and font.get_string_size(name_, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > room:
			fs -= 4
		var base := face.y + fs * 0.3 - 8.0
		draw_string_outline(font, Vector2(left, base), name_, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 6, Color.WHITE)
		draw_string(font, Vector2(left, base), name_, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, ink)
