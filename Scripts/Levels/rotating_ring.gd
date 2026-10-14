@tool
extends AnimatableBody3D
## Level 2: a ring wall with one gap that spins around its centre. Built from
## box segments; the gap faces local +Z before rotation.
## 第二关:带一个缺口、绕中心旋转的环形墙。由长方体分段拼成,
## 未旋转时缺口朝向局部 +Z。

## Spin speed in degrees per second. Adjustable while the game runs.
## 旋转速度(度/秒)。游戏运行时也可以调。
@export_range(0.0, 360.0, 0.5) var speed_degrees: float = 20.0
## Clockwise when viewed from above; off = counter-clockwise.
## 俯视顺时针;关掉就是逆时针。
@export var clockwise: bool = true
## Ring centre-line radius (m).
## 环中线半径(米)。
@export_range(0.5, 100.0, 0.1) var radius: float = 5.0:
	set(value):
		radius = value
		_queue_rebuild()
## Wall thickness (m).
## 墙厚(米)。
@export_range(0.1, 10.0, 0.05) var thickness: float = 0.8:
	set(value):
		thickness = value
		_queue_rebuild()
## Height above the water (m); the wall also sinks 1 m below it.
## 露出水面的高度(米);墙另外还有 1 米埋在水下。
@export_range(0.1, 20.0, 0.1) var height: float = 1.5:
	set(value):
		height = value
		_queue_rebuild()
## Width of the gap (degrees of arc).
## 缺口宽度(圆弧角度)。
@export_range(1.0, 359.0, 1.0) var gap_degrees: float = 40.0:
	set(value):
		gap_degrees = value
		_queue_rebuild()
## Segments a full circle would have; more = smoother ring.
## 整圈的分段数,越多环越圆滑。
@export_range(8, 256, 1) var segments: int = 48:
	set(value):
		segments = value
		_queue_rebuild()
@export var color: Color = Color(0.55, 0.45, 0.35):
	set(value):
		color = value
		_queue_rebuild()

const SUNK_DEPTH := 1.0

var _generated: Array[Node] = []
var _pending := false


func _ready() -> void:
	_rebuild()


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	# Positive Y rotation is counter-clockwise seen from above.
	# 绕 Y 轴正向旋转在俯视下是逆时针。
	var dir := -1.0 if clockwise else 1.0
	rotate_y(deg_to_rad(speed_degrees) * dir * delta)


func _queue_rebuild() -> void:
	if not is_inside_tree() or _pending:
		return
	_pending = true
	_rebuild.call_deferred()


func _rebuild() -> void:
	_pending = false
	for n in _generated:
		n.queue_free()
	_generated.clear()

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.85

	var arc := deg_to_rad(360.0 - gap_degrees)
	var count := maxi(1, roundi(segments * arc / TAU))
	var step := arc / count
	var total_h := height + SUNK_DEPTH
	# Length at the outer edge so neighbouring segments close up without seams.
	# 用外沿的弦长,相邻段之间不留缝。
	var seg_len := 2.0 * (radius + thickness * 0.5) * tan(step * 0.5)
	var size := Vector3(seg_len, total_h, thickness)

	var box := BoxMesh.new()
	box.size = size
	box.material = mat
	var shape := BoxShape3D.new()
	shape.size = size

	var start := deg_to_rad(gap_degrees) * 0.5
	for i in count:
		var a := start + step * (i + 0.5)
		var rot := Basis(Vector3.UP, a)
		var pos := rot * Vector3(0.0, 0.0, radius)
		pos.y = total_h * 0.5 - SUNK_DEPTH
		var xf := Transform3D(rot, pos)

		var mesh := MeshInstance3D.new()
		mesh.mesh = box
		mesh.transform = xf
		_add(mesh)

		var col := CollisionShape3D.new()
		col.shape = shape
		col.transform = xf
		_add(col)


func _add(n: Node) -> void:
	add_child(n)
	_generated.append(n)
