extends CanvasLayer
## Draws MediaPipe hand landmarks as a full-screen 2D overlay.

const CONNECTIONS := [
	[0, 1], [1, 2], [2, 3], [3, 4],
	[0, 5], [5, 6], [6, 7], [7, 8],
	[5, 9], [9, 10], [10, 11], [11, 12],
	[9, 13], [13, 14], [14, 15], [15, 16],
	[0, 17], [13, 17], [17, 18], [18, 19], [19, 20],
]

var _mode: String = "hidden"
var _draw: Control


func _ready() -> void:
	_draw = Control.new()
	_draw.set_anchors_preset(Control.PRESET_FULL_RECT)
	_draw.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_draw.draw.connect(_on_draw)
	add_child(_draw)
	_draw.visible = false


func set_mode(mode: String) -> void:
	_mode = mode
	_draw.visible = mode != "hidden"
	_draw.queue_redraw()


func _process(_delta: float) -> void:
	if _draw.visible:
		_draw.queue_redraw()


func _on_draw() -> void:
	if _mode == "hidden":
		return
	var scale := _draw.get_viewport_rect().size
	_draw_hand(HandTracking.left_hand, scale, Color(0.4, 0.85, 1.0))
	_draw_hand(HandTracking.right_hand, scale, Color(1.0, 0.55, 0.4))


func _draw_hand(hand: Array, scale: Vector2, color: Color) -> void:
	if hand.is_empty():
		return
	var points: Array[Vector2] = []
	for lm in hand:
		points.append(Vector2(lm.x * scale.x, lm.y * scale.y))
	for pair in CONNECTIONS:
		if pair[0] < points.size() and pair[1] < points.size():
			_draw.draw_line(points[pair[0]], points[pair[1]], color, 2.0)
	for p in points:
		_draw.draw_circle(p, 3.0, color)
