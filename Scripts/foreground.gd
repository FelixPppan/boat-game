extends MeshInstance3D

@export var hover_seconds: float = 1.0
@export var slide_distance: float = 1.3

@onready var hover_area: Area3D = $HoverArea
@onready var memory_preview: Node = get_parent().get_parent()

var hovering: bool = false
var opened: bool = false
var hover_time: float = 0.0
var start_position: Vector3


func _ready() -> void:
	start_position = position

	hover_area.mouse_entered.connect(_on_mouse_entered)
	hover_area.mouse_exited.connect(_on_mouse_exited)


func _process(delta: float) -> void:
	if opened:
		return

	# 等雾气动画结束，才允许探索。
	if memory_preview.get("memory_ready") != true:
		hover_time = 0.0
		return

	if hovering:
		hover_time += delta

		if hover_time >= hover_seconds:
			open_layer()
	else:
		hover_time = 0.0


func _on_mouse_entered() -> void:
	hovering = true


func _on_mouse_exited() -> void:
	hovering = false


func open_layer() -> void:
	# 先锁定展开状态，避免移动后鼠标离开导致反复触发。
	if opened:
		return

	opened = true
	hover_area.input_ray_pickable = false

	var target_position := start_position + Vector3(
		slide_distance, 0.0, 0.0
	)

	var tween := create_tween()
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(self, "position", target_position, 0.6)
