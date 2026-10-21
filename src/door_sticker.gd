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


## A Finnish-style plate: white, black border, black condensed letters.
class PlateArt extends Control:
	var text: String

	func _draw() -> void:
		var font: Font = load("res://assets/fonts/BarlowCondensed-ExtraBoldItalic.ttf")
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.08, 0.08, 0.1))
		draw_rect(Rect2(Vector2(6, 6), size - Vector2(12, 12)), Color(0.94, 0.94, 0.92))
		var blue := Rect2(Vector2(6, 6), Vector2(size.y * 0.32, size.y - 12))
		draw_rect(blue, Color(0.1, 0.25, 0.65))
		var left := blue.end.x + 8.0
		var room := size.x - left - 14.0
		# Big glyphs come out as solid boxes on some drivers, so the size is capped.
		var fs := mini(int(size.y * 0.8), 90)
		while fs > 12 and font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > room:
			fs -= 2
		var base := size.y * 0.5 + fs * 0.34
		draw_string(font, Vector2(left, base), text, HORIZONTAL_ALIGNMENT_CENTER, room, fs, Color(0.06, 0.06, 0.07))


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
