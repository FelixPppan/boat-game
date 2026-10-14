extends CharacterBody3D

signal rowing_animation_changed(action: StringName)

var _rowing_animation: StringName = &"idle"
## The boat's motion. Two input paths:
##   1. sensor   -- OarController works out this stroke's thrust and yaw torque (default)
##   2. keyboard -- takes over automatically when no sensor is connected (WASD), so the
##                  game is still playable without the oar
##
## Motion is integrated, not "hold a key = slide at a constant speed":
##   acceleration  = (oar thrust + water drag) / mass
##   angular accel = yaw torque / yaw inertia - angular damping
## so releasing the oar coasts on momentum and gets dragged to a stop by the water --
## that is the "natural water resistance". Every handling knob is below; edit and rerun.
##
## 船的运动。两条输入路径:
##   1. 传感器 —— OarController 算出这一桨的推力和偏转力矩(默认)
##   2. 键盘   —— 没有传感器时自动接管(WASD),所以没有桨也能玩
##
## 运动是积分出来的,不是「按住键 = 匀速滑动」:
##   加速度     = (桨推力 + 水阻) / 质量
##   角加速度   = 偏转力矩 / 转动惯量 - 角阻尼
## 所以松开桨会靠惯性滑行、被水拖到停下 —— 这就是「自然水阻」。手感旋钮都在下面,改完重跑。

# --------------------------------------- Handling / 手感调参 (中英对照) ----
@export_group("Hull")
## Total mass of boat + paddler (kg). Heavier = slower to accelerate, longer
## to coast.
## 船 + 人的总质量(kg)。越大越「重」,加速越慢、滑行越久。
@export_range(1.0, 2000.0, 1.0) var mass: float = 220.0
## Thrust produced by one full-power stroke (N).
## 一记满力划桨产生的推进力(N)。想整体更快就调大。
@export_range(0.0, 5000.0, 10.0) var max_thrust: float = 900.0
## Yaw inertia (kg*m^2). Larger = the bow turns more slowly and steadily.
## 转动惯量(kg·m²)。越大船头转得越慢越稳。
@export_range(1.0, 5000.0, 1.0) var yaw_inertia: float = 520.0

@export_group("Water drag")
## Linear drag, dominant at low speed (viscous friction). N / (m/s).
## 线性阻力:低速时主导(粘性摩擦)。单位 N / (m/s)。
@export_range(0.0, 1000.0, 1.0) var linear_drag: float = 40.0
## Quadratic drag, dominant at high speed (wake, splash). N / (m/s)^2.
## 二次阻力:高速时主导(兴波、拍水)。单位 N / (m/s)²。
## 这两个一起决定最高速度:推力等于阻力时船就不再加速。
@export_range(0.0, 1000.0, 1.0) var quadratic_drag: float = 30.0
## Angular damping, so the boat does not spin forever.
## 角速度阻尼,让船不会一直转圈。
@export_range(0.0, 20.0, 0.1) var yaw_drag: float = 1.5
## Hard cap on yaw rate (rad/s), a backstop against spinning in place.
## 最大角速度(rad/s),兜底防止原地打转。
@export_range(0.01, 10.0, 0.01) var max_yaw_rate: float = 1.2

@export_group("Keyboard fallback")
## Keyboard thrust as a fraction of max_thrust.
## 键盘推进力相对于 max_thrust 的比例。
@export var keyboard_thrust: float = 0.6
## Keyboard turn torque as a fraction of max_thrust.
## 键盘转向力矩相对于 max_thrust 的比例。
@export var keyboard_turn: float = 0.6

@export_group("Camera")
## Maximum camera bank while turning, in degrees.
## 转向时相机倾斜的最大角度。
@export var camera_tilt_degrees: float = 6.0
## How fast the bank follows (larger = snappier).
## 倾斜跟随的快慢(越大越跟手)。
@export var camera_tilt_smoothing: float = 6.0
## If true, the camera follows the boat on XZ/yaw but stays at calm-water
## height so wave bobbing does not bounce the view.
## 开启后镜头仍跟随船的平移和转向,但高度锁在平静水面,不随浪上下晃。
@export var camera_ignore_waves: bool = true

@export_group("Wave following")
## Rest height of the boat origin above calm water (y = 0).
## 平静水面(y=0)上船原点的基准高度。
@export var float_height: float = 0.44
## How quickly the hull tracks the wave height (larger = snappier).
## 船体跟随浪高的快慢(越大越跟手)。
@export var wave_follow_smoothing: float = 8.0
## How quickly the hull follows an external lift such as a water jet, and
## falls back once it stops (larger = snappier).
## 被水柱等外力顶起、以及失去顶力后落回水面的快慢(越大越跟手)。
@export var lift_smoothing: float = 4.0

@export_group("Debug UI")
## Show the top-right FORWARD SWEEP gyro tuning panel.
## 是否显示右上角 FORWARD SWEEP 陀螺仪调参面板。
@export var show_forward_sweep_panel: bool = false:
	set(value):
		show_forward_sweep_panel = value
		if _oar != null:
			_oar.show_panel = show_forward_sweep_panel

# preload rather than the bare class name: a class name is only recognised
# once the editor has scanned it into the .godot cache, whereas this path
# always resolves.
# 用 preload 而不是裸类名:类名要等编辑器扫进 .godot 缓存才认得,而这个路径永远能解析。
const OarControllerScript := preload("res://Scripts/oar_controller.gd")
const TrailDotsScript := preload("res://Scripts/trail_dots.gd")
const StrokeRecorderScript := preload("res://Scripts/stroke_recorder.gd")
const TrailScript := preload("res://Scripts/trail.gd")

@onready var camera: Camera3D = $Camera3D
@onready var _water: Node = get_node_or_null("/root/Map/WaterPlane")

## Planar velocity in world space (only x/z are used).
## 世界坐标下的平面速度(只用 x/z)。
var _vel := Vector3.ZERO
## Current yaw rate (rad/s); positive turns left.
## 当前偏航角速度(rad/s),正值向左转。
var _yaw_rate := 0.0
var _camera_tilt := 0.0
## Camera local Y from the scene, used to cancel wave bob on the view.
## 从场景里取来的相机局部 Y,用来抵消镜头上的浪涌起伏。
var _camera_rest_local_y: float = 0.0
## Current height above the waves from external lift, and the strongest lift
## requested since the last physics frame.
## 外力顶起的当前高度(相对波面),以及上一物理帧以来收到的最大顶升请求。
var _lift := 0.0
var _lift_request := 0.0
var _oar
var _trail
var _recorder


func _ready() -> void:
	# The boat floats: there is no notion of ground, so use floating mode
	# (no gravity, no snapping to a floor).
	# 船是漂着的:没有地面这个概念,所以用 floating 模式(无重力、不吸到地面)。
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	add_to_group("player_boat")
	_camera_rest_local_y = camera.position.y

	# The controller is created in code so the scene file needs no edits.
	# 控制器用代码建,所以场景文件不用改。
	_oar = OarControllerScript.new()
	_oar.name = "OarController"
	# Its panel prints "thrust X of Y" in newtons; Y is ours, so hand it over rather
	# than letting the controller keep its own copy that retuning here would falsify.
	# 它的面板按牛顿打印「推力 X / Y」,Y 是这边的数,所以交过去 —— 免得控制器自己存一份、
	# 这边一调这边就成了假数。
	_oar.max_thrust_report = max_thrust
	_oar.show_panel = show_forward_sweep_panel
	add_child(_oar)

	# Stern trail history → aurora mist in waves.gdshader.
	# 船尾航迹的历史数据 → waves.gdshader 里的极光雾。
	_trail = TrailScript.new()
	_trail.name = "Trail"
	add_child(_trail)
	_trail.setup(self)

	# Records the raw oar stream, for offline scoring -- see
	# Scripts/stroke_recorder.gd. Inert until R is pressed, and it talks to the
	# SensorInput autoload directly rather than to the controller, so nothing has
	# to be handed to it.
	# 录下原始桨数据,供离线打分 —— 见 Scripts/stroke_recorder.gd。不按 R 就完全不动,
	# 而且它直接和 SensorInput 这个 autoload 打交道、不碰控制器,所以没有什么要交给它。
	_recorder = StrokeRecorderScript.new()
	_recorder.name = "StrokeRecorder"
	add_child(_recorder)


func _unhandled_input(event: InputEvent) -> void:
	# Quit the game. _unhandled_input rather than _input so the overlay keys
	# (F1/F2/F3) get first refusal; those handlers do not mark the event as
	# handled, so everything still reaches here.
	# 退出游戏。用 _unhandled_input 而不是 _input,好让叠加层的按键(F1/F2/F3)先挑;
	# 那些处理函数不把事件标记为已处理,所以事件仍然会到这里。
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_ESCAPE:
		get_tree().quit()


func _physics_process(delta: float) -> void:
	_oar.update(delta)

	# --- 1. Collect force and torque (boat frame: x right, z back) --------
	# --- 1. 收集推力与力矩(船体坐标:x 向右,z 向后)
	var thrust_local := Vector3.ZERO
	var yaw_torque := 0.0

	if _oar.sensor_ready:
		thrust_local = _oar.thrust_local() * max_thrust
		yaw_torque = _oar.yaw_torque() * max_thrust
	else:
		# --- keyboard fallback ---
		# --- 键盘兜底 ---
		var forward_input := 0.0
		if Input.is_key_pressed(KEY_W):
			forward_input += 1.0
		if Input.is_key_pressed(KEY_S):
			forward_input -= 1.0
		thrust_local.z = -forward_input * keyboard_thrust * max_thrust

		var turn_input := 0.0
		if Input.is_key_pressed(KEY_A):
			turn_input += 1.0
		if Input.is_key_pressed(KEY_D):
			turn_input -= 1.0
		yaw_torque = turn_input * keyboard_turn * max_thrust

	_update_rowing_animation(thrust_local, yaw_torque)

	# --- 2. Rotate the thrust into world space ---------------------------
	# --- 2. 把推力转到世界坐标
	var thrust_world := global_transform.basis * thrust_local
	thrust_world.y = 0.0      # planar motion only; the boat does not bob / 只取平面运动,船不上下浮沉

	# --- 3. Linear: inertia + water drag ---------------------------------
	# --- 3. 直线:惯性 + 水阻
	# Force -> acceleration -> change in velocity. This step is the inertia.
	# 力 -> 加速度 -> 速度的变化。这一步就是惯性。
	_vel += thrust_world / mass * delta

	var speed := _vel.length()
	if speed > 0.001:
		# Drag = linear term + quadratic term, always opposing the velocity.
		# This is what gives the boat a natural top speed (it stops
		# accelerating once thrust and drag balance out).
		# 阻力 = 线性项 + 二次项,永远与速度反向。这就是船自然有最高速度的原因:
		# 推力和阻力打平之后就不再加速。
		var drag_mag := linear_drag * speed + quadratic_drag * speed * speed
		_vel -= _vel / speed * (drag_mag / mass) * delta
	else:
		_vel = Vector3.ZERO

	# --- 4. Turning: torque -> angular accel -> yaw rate -----------------
	# --- 4. 转向:力矩 -> 角加速度 -> 偏航角速度
	_yaw_rate += yaw_torque / yaw_inertia * delta
	# Angular damping, or the boat would keep spinning faster and faster.
	# 角速度阻尼,不然船会越转越快。
	_yaw_rate = lerp(_yaw_rate, 0.0, clampf(yaw_drag * delta, 0.0, 1.0))
	_yaw_rate = clampf(_yaw_rate, -max_yaw_rate, max_yaw_rate)
	rotate_y(_yaw_rate * delta)

	# --- 5. Hand it to the physics engine --------------------------------
	# --- 5. 交给物理引擎
	velocity = _vel
	move_and_slide()
	# Hitting an island or rock makes the engine rewrite velocity; sync it
	# back so the boat cannot keep banking speed while stuck in an obstacle.
	# 撞到岛或石头时引擎会改写 velocity,同步回来,免得船卡在障碍里还在攒速度。
	_vel = velocity
	_vel.y = 0.0

	# --- 6. Ride the Gerstner surface ------
	# --- 6. 跟随 Gerstner 波面
	# Buoyancy Boat uses forces; we just snap/lerp Y to the same height field.
	# Buoyancy Boat 用的是力;这里只是把 Y 贴/插值到同一个高度场。
	_follow_wave_height(delta)

	_update_camera_tilt(delta)
	_stabilize_camera_height()

	if _trail != null:
		_trail.external_speed = Vector2(_vel.x, _vel.z).length()


## Push the boat up to `height` metres above the waves for this physics frame.
## Call every frame to hold it there; stop calling and it falls back.
## 本物理帧把船顶到波面以上 `height` 米。每帧调用才能保持住;不再调用就会落回去。
func add_lift(height: float) -> void:
	_lift_request = maxf(_lift_request, height)


func _follow_wave_height(delta: float) -> void:
	_lift = lerpf(_lift, _lift_request, 1.0 - exp(-lift_smoothing * delta))
	_lift_request = 0.0
	if _water == null or not _water.has_method("get_height"):
		return
	var target_y := float_height + _lift + float(_water.get_height(global_position))
	var t := 1.0 - exp(-wave_follow_smoothing * delta)
	global_position.y = lerpf(global_position.y, target_y, t)


## Keep the camera child of the boat (so XZ + yaw still follow), but cancel
## the wave offset on its local Y so the view does not bob.
## 让相机继续做船的子节点(平移和转向照旧跟随),但把它局部的 Y 上的浪高偏移抵消掉,
## 于是镜头不上下晃。
func _stabilize_camera_height() -> void:
	if not camera_ignore_waves:
		camera.position.y = _camera_rest_local_y
		return
	# global_y = boat.y + local_y  (boat only yaws) → lock to calm height.
	# global_y = 船的 y + 局部 y(船只会偏航),于是锁到平静高度。
	camera.position.y = _camera_rest_local_y + float_height + _lift - global_position.y


func _update_camera_tilt(delta: float) -> void:
	# Bank the camera slightly into the turn; the boat stays centred on screen
	# because the camera is a child of the boat and shares its rotation pivot.
	# 转向时让相机微微侧倾;船在屏幕上仍然居中,因为相机是船的子节点、共用它的旋转轴。
	var t := clampf(_yaw_rate / max_yaw_rate, -1.0, 1.0)
	var target_tilt := deg_to_rad(camera_tilt_degrees) * t
	_camera_tilt = lerp(_camera_tilt, target_tilt,
		1.0 - exp(-camera_tilt_smoothing * delta))
	camera.rotation.z = _camera_tilt

func _update_rowing_animation(thrust: Vector3, torque: float) -> void:
	var action: StringName = &"idle"
	if thrust.length_squared() > 0.01:
		action = &"forward"
	if torque > 0.01:
		action = &"left"
	elif torque < -0.01:
		action = &"right"
	if action != _rowing_animation:
		_rowing_animation = action
		rowing_animation_changed.emit(action)
