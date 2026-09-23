extends Area3D

@export var memory_fog_volume: FogVolume
var is_boat_near: bool = false
var is_cleared: bool = false

func _ready() -> void:
	body_entered.connect(func(b): if b.is_in_group("Boat") or b.name == "Boat": is_boat_near = true)
	body_exited.connect(func(b): if b.is_in_group("Boat") or b.name == "Boat": is_boat_near = false)

func _process(_delta: float) -> void:
	# Temporary Test: Press the spacebar to trigger 临时测试：按下空格触发 
	if is_boat_near and not is_cleared:
		if Input.is_action_just_pressed("ui_accept"):
			trigger_dispel()

## 公开接口：供外部手势识别、传感器信号或按键统一调用
## Interface: for accessing external gesture recognition, sensor signals, or button inputs
func trigger_dispel() -> void:
	# The defrosting process is performed only when the ship is nearby and the fog has not yet cleared.
	# 只有当船在附近且迷雾尚未消散时才执行消融
	if not is_boat_near or is_cleared:
		return
		
	clear_memory_fog_gentle()

func clear_memory_fog_gentle() -> void:
	is_cleared = true
	var mat = memory_fog_volume.material as ShaderMaterial
	if not mat: return
	
	
	var tween = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.tween_method(func(val: float):
		mat.set_shader_parameter("dissolve_factor", val)
	, 1.0, 0.0, 2) # 2秒轻柔消融
