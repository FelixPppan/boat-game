@tool
extends Area3D
## Level goal: a sphere placeholder. The player's boat touching it collects it
## and completes the level.
## 关卡目标:先用球体占位。玩家的船碰到它就收集到,完成这个关卡。

signal collected

## Shown on screen when the goal is collected.
## 收集到时屏幕上显示的关卡名。
@export var level_name: String = "Level"
## Sphere radius (m). The pickup area is slightly larger than the visible ball.
## 球的半径(米)。拾取范围比看得见的球略大一点。
@export_range(0.1, 10.0, 0.05) var radius: float = 1.0:
	set(value):
		radius = value
		_rebuild()
@export var color: Color = Color(1.0, 0.82, 0.2):
	set(value):
		color = value
		_rebuild()

var _generated: Array[Node] = []
var _done := false


func _ready() -> void:
	_rebuild()
	if not Engine.is_editor_hint():
		add_to_group("level_target")
		body_entered.connect(_on_body_entered)


func _rebuild() -> void:
	if not is_inside_tree():
		return
	for n in _generated:
		n.queue_free()
	_generated.clear()

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 1.5

	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	sphere.material = mat
	var mesh := MeshInstance3D.new()
	mesh.mesh = sphere
	_add(mesh)

	var shape := SphereShape3D.new()
	shape.radius = radius * 1.2
	var col := CollisionShape3D.new()
	col.shape = shape
	_add(col)


func _add(n: Node) -> void:
	add_child(n)
	_generated.append(n)


func _on_body_entered(body: Node) -> void:
	if _done or not body.is_in_group("player_boat"):
		return
	_done = true
	visible = false
	set_deferred("monitoring", false)
	print("[%s] %s complete!" % [get_parent().name, level_name])
	_show_banner()
	collected.emit()


func _show_banner() -> void:
	var layer := CanvasLayer.new()
	var label := Label.new()
	label.text = "%s Complete!" % level_name
	label.add_theme_font_size_override("font_size", 56)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	label.offset_top = 80.0
	layer.add_child(label)
	get_tree().root.add_child(layer)
	get_tree().create_timer(3.0).timeout.connect(layer.queue_free)
