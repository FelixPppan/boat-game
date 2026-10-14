@tool
extends StaticBody3D
## One reef (box placeholder). Move / rotate it with the gizmo; change its
## size and colour in the Inspector rather than scaling the node, so the
## collision shape stays unscaled.
## 一块礁石(长方体占位)。用变换工具移动 / 旋转;尺寸和颜色在检查器里改,
## 不要直接缩放节点,这样碰撞形状不会被拉伸。

## Box size (m). The bottom SUNK_DEPTH metres sit below the water.
## 长方体尺寸(米)。最下面 SUNK_DEPTH 米埋在水下。
@export var size: Vector3 = Vector3(1.2, 2.5, 2.5):
	set(value):
		size = value
		_rebuild()
@export var color: Color = Color(0.32, 0.3, 0.3):
	set(value):
		color = value
		_rebuild()

const SUNK_DEPTH := 1.0

var _generated: Array[Node] = []


func _ready() -> void:
	_rebuild()


func _rebuild() -> void:
	if not is_inside_tree():
		return
	for n in _generated:
		n.queue_free()
	_generated.clear()

	var offset := Vector3(0.0, size.y * 0.5 - SUNK_DEPTH, 0.0)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.9
	var box := BoxMesh.new()
	box.size = size
	box.material = mat
	var mesh := MeshInstance3D.new()
	mesh.mesh = box
	mesh.position = offset
	_add(mesh)

	var shape := BoxShape3D.new()
	shape.size = size
	var col := CollisionShape3D.new()
	col.shape = shape
	col.position = offset
	_add(col)


func _add(n: Node) -> void:
	add_child(n)
	_generated.append(n)
