extends Node

# 仅用于测试场景的汇报演示，不属于记忆组件。
@export var enabled: bool = true
@export var memory: Node
@export var camera: Camera3D
@export_range(0.0, 2.0, 0.1) var push_distance: float = 1.5
@export_range(0.1, 6.0, 0.1) var move_duration: float = 2.8

var start_position: Vector3


func _ready() -> void:
	start_position = camera.position
	memory.reveal_started.connect(_push_in)


func _push_in() -> void:
	if not enabled:
		return
	var target := start_position - camera.basis.z * push_distance
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(camera, "position", target, move_duration)
