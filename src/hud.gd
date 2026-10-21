class_name Hud
extends Control
## One player's instruments over their view: the co-driver's next call at
## the top, stage time top left, gear, speed and revs bottom right, and
## where everyone is on the stage along the left edge. Little else.

var main: Node
var index := 0
## Absolute point arrays retain the original float arithmetic and draw positions.
## At a fixed size there are two note slots, seven grades and two directions.
var _corner_geometry := {}
var _crest_geometry := {}
var _pace_geometry_scale := -1.0


func _ready() -> void:
	resized.connect(_clear_pace_geometry)


func _clear_pace_geometry() -> void:
	_corner_geometry.clear()
	_crest_geometry.clear()
	_pace_geometry_scale = -1.0


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if main == null or index >= main.players.size() or main.stage == null:
		return
	var p: Dictionary = main.players[index]
	var car: Car = p.car
	if car == null:
		return
	var font: Font = Look.font()
	var s := size
	var scale_ := clampf(s.y / 1080.0, 0.5, 1.0) * (1.25 if s.y < 600.0 else 1.0)
	var pad := 28.0 * scale_
	var shade := Color(0.03, 0.035, 0.04, 0.55)
	# Stage time.
	var t: float = maxf(main.clock, 0.0) + p.penalty
	if p.finished:
		t = p.time
	var time_text: String = main.format_time(t)
	draw_rect(Rect2(pad, pad, 210 * scale_, 56 * scale_), shade)
	draw_string(font, Vector2(pad + 16 * scale_, pad + 44 * scale_), time_text, HORIZONTAL_ALIGNMENT_LEFT, -1, int(42 * scale_), Color.WHITE)
	if p.penalty > 0.0:
		draw_string(font, Vector2(pad + 16 * scale_, pad + 84 * scale_), "+%d s" % int(p.penalty), HORIZONTAL_ALIGNMENT_LEFT, -1, int(26 * scale_), Color(1, 0.75, 0.4))
	# Gear, speed, revs.
	var gx := s.x - pad - 230 * scale_
	var gy := s.y - pad - 120 * scale_
	draw_rect(Rect2(gx, gy, 230 * scale_, 120 * scale_), shade)
	var gear := "R" if car.gear < 0 else str(car.gear)
	if car.shift_timer > 0.0:
		gear = "R" if car.shift_target < 0 else str(car.shift_target)
	draw_string(font, Vector2(gx + 18 * scale_, gy + 96 * scale_), gear, HORIZONTAL_ALIGNMENT_LEFT, -1, int(96 * scale_), Color.WHITE)
	if car.manual:
		draw_string(font, Vector2(gx + 18 * scale_, gy + 112 * scale_), "M", HORIZONTAL_ALIGNMENT_LEFT, -1, int(18 * scale_), Color(1, 1, 1, 0.6))
	var kmh := int(round(absf(car.speed) * 3.6))
	draw_string(font, Vector2(gx + 80 * scale_, gy + 70 * scale_), str(kmh), HORIZONTAL_ALIGNMENT_RIGHT, 130 * scale_, int(56 * scale_), Color.WHITE)
	draw_string(font, Vector2(gx + 80 * scale_, gy + 98 * scale_), "km/h", HORIZONTAL_ALIGNMENT_RIGHT, 130 * scale_, int(20 * scale_), Color(1, 1, 1, 0.6))
	var rev := clampf(car.rpm() / car.spec.limit_rpm, 0.0, 1.0)
	var bar := Rect2(gx, gy - 12 * scale_, 230 * scale_, 8 * scale_)
	draw_rect(bar, Color(0, 0, 0, 0.5))
	var hot := rev > 0.92
	draw_rect(Rect2(bar.position, Vector2(bar.size.x * rev, bar.size.y)), Color(1.0, 0.25, 0.15) if hot else Color(0.95, 0.95, 0.9))
	# Handbrake pulled.
	if car.handbrake > 0.1:
		var hb := Rect2(gx - 78 * scale_, gy + 64 * scale_, 66 * scale_, 56 * scale_)
		draw_rect(hb, Color(0.95, 0.45, 0.1, 0.9))
		draw_string(font, Vector2(hb.position.x, hb.position.y + 42 * scale_), "HB", HORIZONTAL_ALIGNMENT_CENTER, hb.size.x, int(38 * scale_), Color.WHITE)
	# Off the road for a moment: say how to get back.
	if not p.bot and p.get("off_track", 0.0) > 1.2 and not p.finished:
		var w := 360.0 * scale_
		var r := Rect2(s.x / 2 - w / 2, s.y - pad - 70 * scale_, w, 56 * scale_)
		draw_rect(r, shade)
		draw_string(font, Vector2(r.position.x + 22 * scale_, r.position.y + 42 * scale_), "X", HORIZONTAL_ALIGNMENT_LEFT, -1, int(38 * scale_), Color(1, 0.82, 0.3))
		draw_string(font, Vector2(r.position.x + 64 * scale_, r.position.y + 40 * scale_), "Back on the road", HORIZONTAL_ALIGNMENT_LEFT, -1, int(32 * scale_), Color.WHITE)
	# Co-driver: the next call.
	_pace_note(p, font, scale_)
	# Everyone on the stage: a line on the left, a dot per car.
	var lx := pad + 6 * scale_
	var top := pad + 120 * scale_
	var bottom := s.y - pad - 20 * scale_
	draw_line(Vector2(lx, top), Vector2(lx, bottom), Color(1, 1, 1, 0.35), 3.0 * scale_)
	for q in main.players:
		var f: float = clampf(q.along / main.stage.finish, 0.0, 1.0)
		var y := lerpf(bottom, top, f)
		var r := (9.0 if q == p else 6.0) * scale_
		draw_circle(Vector2(lx, y), r, q.color)
		if q == p:
			draw_arc(Vector2(lx, y), r + 2.0, 0, TAU, 20, Color.WHITE, 2.0)
	# Start lights.
	if main.phase == "countdown":
		var left: float = -main.clock
		var lit := ceili(left)
		var c := Vector2(s.x / 2, s.y * 0.3)
		for i in 3:
			var on := i < lit
			draw_circle(c + Vector2((i - 1) * 70 * scale_, 0), 26 * scale_, Color(0.9, 0.08, 0.05) if on else Color(0.12, 0.12, 0.12, 0.8))
	elif main.phase == "racing" and main.clock < 1.0:
		var c := Vector2(s.x / 2, s.y * 0.3)
		for i in 3:
			draw_circle(c + Vector2((i - 1) * 70 * scale_, 0), 26 * scale_, Color(0.15, 0.85, 0.2))
	if p.finished and main.phase != "results":
		var pos: int = main.standings().find(p) + 1
		var c := Vector2(s.x / 2, s.y * 0.32)
		draw_rect(Rect2(c - Vector2(200, 60) * scale_, Vector2(400, 110) * scale_), shade)
		draw_string(font, c + Vector2(-200, 10) * scale_, main.format_time(p.time), HORIZONTAL_ALIGNMENT_CENTER, 400 * scale_, int(64 * scale_), Color.WHITE)
		draw_string(font, c + Vector2(-200, 44) * scale_, "P%d" % pos, HORIZONTAL_ALIGNMENT_CENTER, 400 * scale_, int(28 * scale_), p.color.lightened(0.3))


func _pace_note(p: Dictionary, font: Font, k: float) -> void:
	if k != _pace_geometry_scale:
		_clear_pace_geometry()
		_pace_geometry_scale = k
	var notes: Array = main.stage.notes
	var along: float = p.along
	var car: Car = p.car
	var reach := 60.0 + absf(car.speed) * 3.2
	var shown := 0
	var x := size.x / 2 - 90 * k
	for n in notes:
		if n.end < along - 2.0 or n.at > along + reach:
			continue
		if shown >= 2:
			break
		var c := Vector2(x + shown * 150 * k, 28 * k + 62 * k)
		var near := 1.0 if shown == 0 else 0.6
		draw_rect(Rect2(c - Vector2(66, 62) * k, Vector2(132, 124) * k), Color(0.03, 0.035, 0.04, 0.6 * near))
		var col := Color(1, 1, 1, near)
		if n.kind == "crest":
			# A crest: a hump.
			if not _crest_geometry.has(c):
				var points := PackedVector2Array()
				for i in 13:
					var u := (i / 12.0) * 2.0 - 1.0
					points.append(c + Vector2(u * 46, 18 - (1.0 - u * u) * 34) * k)
				_crest_geometry[c] = points
			var pts: PackedVector2Array = _crest_geometry[c]
			draw_polyline(pts, col, 7 * k)
		else:
			_corner_icon(c, n.kind == "left", n.grade, col, k)
			var label := "H" if n.grade == 0 else str(n.grade)
			draw_string(font, c + Vector2(-60, 54) * k, label, HORIZONTAL_ALIGNMENT_CENTER, 120 * k, int(34 * k), col)
		shown += 1


## An arrow bending left or right; the tighter the corner, the sharper the bend.
func _corner_icon(c: Vector2, left: bool, grade: int, col: Color, k: float) -> void:
	if not _corner_geometry.has(c):
		_corner_geometry[c] = {}
	var variants: Dictionary = _corner_geometry[c]
	var key := Vector2i(grade, int(left))
	if not variants.has(key):
		var bend := lerpf(170.0, 20.0, grade / 6.0)
		if grade == 0:
			bend = 180.0
		var dir := -1.0 if left else 1.0
		var pts := PackedVector2Array()
		var start := c + Vector2(-dir * 18, 30) * k
		var pos := start
		var heading := -PI / 2
		pts.append(pos)
		var seg := 28.0 * k
		pts.append(pos + Vector2(0, -seg))
		pos += Vector2(0, -seg)
		var steps := 8
		var r := 34.0 * k * (0.5 if grade == 0 else 1.0)
		for i in steps:
			heading += dir * deg_to_rad(bend) / steps
			pos += Vector2(cos(heading), sin(heading)) * r * deg_to_rad(bend) / steps
			pts.append(pos)
		var tip := pos
		var back := Vector2(cos(heading), sin(heading))
		var side := Vector2(-back.y, back.x)
		variants[key] = [pts, PackedVector2Array([tip + back * 14 * k, tip - back * 4 * k + side * 13 * k, tip - back * 4 * k - side * 13 * k])]
	var geometry: Array = variants[key]
	draw_polyline(geometry[0], col, 7 * k)
	draw_colored_polygon(geometry[1], col)
