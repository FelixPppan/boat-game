extends Node3D

## 每秒旋转角度
@export var rotation_speed: float = 15.0
## 上下浮动幅度，单位：米
@export var float_height: float = 0.15
## 完成一次上下浮动需要的秒数
@export_range(0.1, 20.0) var float_period: float = 4.0

var _start_y: float
var _elapsed: float = 0.0


func _ready() -> void:
	_start_y = position.y


func _process(delta: float) -> void:
	_elapsed += delta
	rotate_y(deg_to_rad(rotation_speed) * delta)
	position.y = _start_y + sin(_elapsed * TAU / float_period) * float_height
