extends CharacterBody3D
## The boat's motion. Two input paths:
##   1. sensor  -- OarController works out this stroke's thrust, lateral force
##                 and yaw torque (the default)
##   2. keyboard -- takes over automatically when no sensor is connected
##                  (WASD), so the game is still playable without the oar
##
## Motion is no longer "hold a key = slide at a constant speed". It is really
## integrated now:
##   acceleration     = (oar thrust + water drag) / mass
##   angular accel    = yaw torque / yaw inertia - angular damping
## so releasing the oar lets the boat coast on its momentum and get dragged to
## a stop by the water. That is the "natural water resistance".
##
## Every handling knob is below; edit and rerun, no editor restart needed.

# --------------------------------------- Handling / 手感调参 (中英对照) ----
@export_group("Hull")
## Total mass of boat + paddler (kg). Heavier = slower to accelerate, longer
## to coast.
## 船 + 人的总质量(kg)。越大越「重」,加速越慢、滑行越久。
@export_range(1.0, 2000.0, 1.0) var mass: float = 180.0
## Thrust produced by one full-power stroke (N).
## 一记满力划桨产生的推进力(N)。想整体更快就调大。
@export_range(0.0, 5000.0, 10.0) var max_thrust: float = 600.0
## Yaw inertia (kg*m^2). Larger = the bow turns more slowly and steadily.
## 转动惯量(kg·m²)。越大船头转得越慢越稳。
@export_range(1.0, 5000.0, 1.0) var yaw_inertia: float = 400.0

@export_group("Water drag")
## Linear drag, dominant at low speed (viscous friction). N / (m/s).
## 线性阻力:低速时主导(粘性摩擦)。单位 N / (m/s)。
@export_range(0.0, 1000.0, 1.0) var linear_drag: float = 60.0
## Quadratic drag, dominant at high speed (wake, splash). N / (m/s)^2.
## 二次阻力:高速时主导(兴波、拍水)。单位 N / (m/s)²。
## 这两个一起决定最高速度:推力等于阻力时船就不再加速。
@export_range(0.0, 1000.0, 1.0) var quadratic_drag: float = 60.0
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

# preload rather than the bare class name: a class name is only recognised
# once the editor has scanned it into the .godot cache, whereas this path
# always resolves.
const OarControllerScript := preload("res://Scripts/oar_controller.gd")
const TrailDotsScript := preload("res://Scripts/trail_dots.gd")

@onready var camera: Camera3D = $Camera3D
@onready var _water: Node = get_node_or_null("/root/Map/WaterPlane")

## Planar velocity in world space (only x/z are used).
var _vel := Vector3.ZERO
## Current yaw rate (rad/s); positive turns left.
var _yaw_rate := 0.0
var _camera_tilt := 0.0
## Camera local Y from the scene, used to cancel wave bob on the view.
var _camera_rest_local_y: float = 0.0
var _oar
var _trail


func _ready() -> void:
	# The boat floats: there is no notion of ground, so use floating mode
	# (no gravity, no snapping to a floor).
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	_camera_rest_local_y = camera.position.y

	# The controller is created in code so the scene file needs no edits.
	_oar = OarControllerScript.new()
	_oar.name = "OarController"
	add_child(_oar)

	# Ticker-tape trail: a green dot every fixed interval, so the spacing
	# between dots reads as speed and the chain reads as the path. Parented to
	# the boat (so it can find it), but the dots themselves stay in the world.
	_trail = TrailDotsScript.new()
	_trail.name = "TrailDots"
	add_child(_trail)
	_trail.setup(self)


func _unhandled_input(event: InputEvent) -> void:
	# Quit the game. _unhandled_input rather than _input so the overlay keys
	# (F1/F2/F3) get first refusal; those handlers do not mark the event as
	# handled, so everything still reaches here.
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_ESCAPE:
		get_tree().quit()


func _physics_process(delta: float) -> void:
	_oar.update(delta)

	# --- 1. Collect force and torque (boat frame: x right, z back) --------
	var thrust_local := Vector3.ZERO
	var yaw_torque := 0.0

	if _oar.sensor_ready:
		thrust_local = _oar.thrust_local() * max_thrust
		yaw_torque = _oar.yaw_torque() * max_thrust
	else:
		# --- keyboard fallback ---
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

	# --- 2. Rotate the thrust into world space ---------------------------
	var thrust_world := global_transform.basis * thrust_local
	thrust_world.y = 0.0      # planar motion only; the boat does not bob

	# --- 3. Linear: inertia + water drag ---------------------------------
	# Force -> acceleration -> change in velocity. This step is the inertia.
	_vel += thrust_world / mass * delta

	var speed := _vel.length()
	if speed > 0.001:
		# Drag = linear term + quadratic term, always opposing the velocity.
		# This is what gives the boat a natural top speed (it stops
		# accelerating once thrust and drag balance out).
		var drag_mag := linear_drag * speed + quadratic_drag * speed * speed
		_vel -= _vel / speed * (drag_mag / mass) * delta
	else:
		_vel = Vector3.ZERO

	# --- 4. Turning: torque -> angular accel -> yaw rate -----------------
	_yaw_rate += yaw_torque / yaw_inertia * delta
	# Angular damping, or the boat would keep spinning faster and faster.
	_yaw_rate = lerp(_yaw_rate, 0.0, clampf(yaw_drag * delta, 0.0, 1.0))
	_yaw_rate = clampf(_yaw_rate, -max_yaw_rate, max_yaw_rate)
	rotate_y(_yaw_rate * delta)

	# --- 5. Hand it to the physics engine --------------------------------
	velocity = _vel
	move_and_slide()
	# Hitting an island or rock makes the engine rewrite velocity; sync it
	# back so the boat cannot keep banking speed while stuck in an obstacle.
	_vel = velocity
	_vel.y = 0.0

	# --- 6. Ride the Gerstner surface (CharacterBody, not RigidBody) ------
	# Buoyancy Boat uses forces; we just snap/lerp Y to the same height field.
	_follow_wave_height(delta)

	_update_camera_tilt(delta)
	_stabilize_camera_height()


func _follow_wave_height(delta: float) -> void:
	if _water == null or not _water.has_method("get_height"):
		return
	var target_y := float_height + float(_water.get_height(global_position))
	var t := 1.0 - exp(-wave_follow_smoothing * delta)
	global_position.y = lerpf(global_position.y, target_y, t)


## Keep the camera child of the boat (so XZ + yaw still follow), but cancel
## the wave offset on its local Y so the view does not bob.
func _stabilize_camera_height() -> void:
	if not camera_ignore_waves:
		camera.position.y = _camera_rest_local_y
		return
	# global_y = boat.y + local_y  (boat only yaws) → lock to calm height.
	camera.position.y = _camera_rest_local_y + float_height - global_position.y


func _update_camera_tilt(delta: float) -> void:
	# Bank the camera slightly into the turn; the boat stays centred on screen
	# because the camera is a child of the boat and shares its rotation pivot.
	var t := clampf(_yaw_rate / max_yaw_rate, -1.0, 1.0)
	var target_tilt := deg_to_rad(camera_tilt_degrees) * t
	_camera_tilt = lerp(_camera_tilt, target_tilt,
		1.0 - exp(-camera_tilt_smoothing * delta))
	camera.rotation.z = _camera_tilt
