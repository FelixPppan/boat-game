extends Node3D

@onready var memory_layers: Node3D = $Memorylayers
@onready var memory_fog: Area3D = $MemoryFog
@onready var fog_visual: MeshInstance3D = $MemoryFog/FogVisual

var picture_layers: Array[MeshInstance3D] = []
var activated: bool = false
var memory_ready: bool = false


func _ready() -> void:
	# 收集图片层，并将它们设为完全透明。
	for child in memory_layers.get_children():
		if child is MeshInstance3D:
			picture_layers.append(child)
			child.transparency = 1.0

	memory_layers.hide()
	memory_fog.show()
	fog_visual.transparency = 0.0

	# 允许鼠标检测，并在代码里连接点击信号。
	get_viewport().physics_object_picking = true
	memory_fog.input_ray_pickable = true
	memory_fog.input_event.connect(_on_fog_input_event)


func _on_fog_input_event(
	_camera: Node,
	event: InputEvent,
	_position: Vector3,
	_normal: Vector3,
	_shape_idx: int
) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			reveal_memory()


func reveal_memory() -> void:
	# 防止连续点击，重复播放动画。
	if activated:
		return

	activated = true
	memory_fog.input_ray_pickable = false
	memory_layers.show()

	# 所有动画同时进行。
	var tween := create_tween()
	tween.set_parallel(true)
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_IN_OUT)

	# 雾气逐渐透明，并稍微向外散开。
	tween.tween_property(fog_visual, "transparency", 1.0, 1.5)
	tween.tween_property(
		fog_visual, "scale", Vector3(1.15, 1.15, 1.0), 1.5
	)

	# 图片稍晚一点开始显现。
	for layer in picture_layers:
		tween.tween_property(
			layer, "transparency", 0.0, 1.4
		).set_delay(0.2)

	await tween.finished

	memory_fog.hide()
	memory_ready = true
