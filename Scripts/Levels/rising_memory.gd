extends Node3D
## Level 3 memory fragment: floats on the sea at first, then rises to its
## placed (editor) position once the boat enters the level, so the player has
## to ride the water jet up to reach it.
## 第三关记忆碎片:开始时漂在海面,船进入关卡范围后升到编辑器里摆放的位置,
## 玩家要借助水柱升高才能交互。

## Level origin used for the trigger distance. 关卡中心(判断距离用)。
@export var level_center: Node3D
## Horizontal distance from the level center that starts the rise (m).
## 船离关卡中心多近(水平,米)时开始上升。
@export_range(1.0, 100.0, 0.5) var trigger_radius: float = 22.0
## How far below the placed position it floats at the start (m).
## 开始时比摆放位置低多少米(漂在海面上)。
@export_range(0.0, 20.0, 0.05) var sink_depth: float = 4.75
@export_range(0.1, 20.0, 0.1) var rise_duration: float = 4.0
## Memory interaction area; it stays off until the rise finishes.
## 记忆交互区域,上升完成前不能交互。
@export var interaction_area: Area3D

var _raised_y: float
var _rising := false
var _boat: Node3D


func _ready() -> void:
	_raised_y = position.y
	position.y -= sink_depth
	if interaction_area:
		interaction_area.monitoring = false


func _process(_delta: float) -> void:
	if _rising or level_center == null:
		return
	if _boat == null:
		_boat = get_tree().get_first_node_in_group("player_boat") as Node3D
		if _boat == null:
			return
	var d := _boat.global_position - level_center.global_position
	if Vector2(d.x, d.z).length() > trigger_radius:
		return
	_rising = true
	var tween := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(self, "position:y", _raised_y, rise_duration)
	tween.finished.connect(_on_risen)


func _on_risen() -> void:
	if interaction_area:
		interaction_area.monitoring = true
