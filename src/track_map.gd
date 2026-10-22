class_name TrackMap
## Tyre tracks on the gravel for the whole stage, in road space: one texel is
## 0.25 m along the road and 1/51 of the road's half width across, so the map
## follows the road however it bends and costs the same anywhere on the stage.
## R is packed gravel where tyres rolled (darker, smoother), G is gravel a
## sliding tyre threw about (lighter, rougher). Wheels stamp it on the CPU and
## only the touched layers of the Texture2DArray are uploaded, a few times a
## second. The road shader reads it.

const ALONG := 0.25 ## metres per row
const COLS := 128 ## texels across, for UV.x -1.25..1.25
const ROWS := 2048 ## rows per layer
const UPLOAD_EVERY := 6 ## physics ticks between uploads

var images: Array[Image] = []
var texture := Texture2DArray.new()
var _dirty := {}
var _tick := 0
var _last := {} ## wheel -> Vector2(col, row) of its last stamp


func _init(stage_length: float) -> void:
	var layers := ceili(stage_length / ALONG / ROWS) + 1
	for i in layers:
		images.append(Image.create_empty(COLS, ROWS, false, Image.FORMAT_RG8))
	texture.create_from_images(images)


## Road UV.x for a lateral offset: linear across the driven width, then the
## shoulder squeezed into 1..1.25, as the road ribbon does.
static func across(offset: float, width: float) -> float:
	var a := absf(offset)
	var u := a / width if a <= width else 1.0 + (a - width) / 0.8 * 0.25
	return signf(offset) * u


## One wheel on the road this tick. `press` 0..1 packs, `scuff` 0..1 throws.
func stamp(key: Object, along: float, u: float, press: float, scuff: float) -> void:
	if absf(u) > 1.25:
		_last.erase(key)
		return
	var col := (u + 1.25) / 2.5 * COLS
	var row := along / ALONG
	var r := floori(row)
	if not _last.has(key) or absf(_last[key].y - row) > 8.0:
		# First touch, a reset or a jump: no streak across the stage.
		_last[key] = Vector2(col, row)
		_paint(r, col, press, scuff)
		return
	var from: Vector2 = _last[key]
	_last[key] = Vector2(col, row)
	# Paint each row the tyre entered since the last tick once, so a pass
	# marks the same however fast it was.
	var f := floori(from.y)
	if f == r:
		# A sideways slide can cross several tyre widths without entering a
		# new longitudinal row. Fill those columns, too, rather than leaving
		# an invisible break in a handbrake turn.
		var first := int(round(from.x))
		var last := int(round(col))
		if first != last:
			var side_step := 1 if last > first else -1
			for x in range(first + side_step, last + side_step, side_step):
				_paint(r, float(x), press * 0.35, scuff * 0.5)
		elif scuff > 0.25 and _tick % UPLOAD_EVERY == 0:
			# A spinning tyre at a standstill still scours the road. Bound the
			# buildup to the existing upload cadence; ordinary parked tyres
			# must not deepen their mark just because another frame elapsed.
			_paint(r, col, press * scuff * 0.12, scuff * 0.25)
		return
	var step := 1 if r > f else -1
	var k := f + step
	while true:
		var t := float(k - f) / float(r - f)
		_paint(k, lerpf(from.x, col, t), press, scuff)
		if k == r:
			break
		k += step


func _paint(row: int, col: float, press: float, scuff: float) -> void:
	var layer := row / ROWS
	if row < 0 or layer >= images.size():
		return
	var img := images[layer]
	var y := row % ROWS
	# A tyre is about 0.22 m wide: three texels with soft sides.
	for dc in [-2, -1, 0, 1, 2]:
		var x: int = int(round(col)) + dc
		if x < 0 or x >= COLS:
			continue
		var fall: float = [0.25, 0.8, 1.0, 0.8, 0.25][dc + 2]
		var c := img.get_pixel(x, y)
		c.r = minf(c.r + press * fall * 0.22, 1.0)
		c.g = minf(c.g + scuff * fall * 0.4, 1.0)
		img.set_pixel(x, y, c)
	_dirty[layer] = true


## How driven-in the gravel is under a wheel, 0..1: grip rises a little on
## the swept line, as on a real stage after a few cars.
func packed(along: float, u: float) -> float:
	var row := int(along / ALONG)
	var layer := row / ROWS
	if row < 0 or layer >= images.size() or absf(u) > 1.25:
		return 0.0
	var x := clampi(int((u + 1.25) / 2.5 * COLS), 0, COLS - 1)
	return images[layer].get_pixel(x, row % ROWS).r


func upload() -> void:
	_tick += 1
	if _tick % UPLOAD_EVERY != 0 or _dirty.is_empty():
		return
	for layer in _dirty:
		texture.update_layer(images[layer], layer)
	_dirty.clear()
