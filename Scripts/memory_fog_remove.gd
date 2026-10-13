extends Area3D

@export var memory_fog_volume: FogVolume
@export var boat_camera: Camera3D
@export var closeup_camera: Camera3D
@export var memory_content: Node
@export var hand_skeleton: Node
@export var boat: Node3D
@export_range(0.2, 1.0, 0.05) var fade_seconds: float = 0.3
@export_range(0.1, 1.0, 0.05) var hand_stable_sec: float = 0.25

var is_boat_near: bool = false
var is_cleared: bool = false

var _engaged: bool = false
var _session_done: bool = false
var _locking: bool = false
var _exploring: bool = false
var _hand_timer: float = 0.0
var _fade: ColorRect

var _env: Environment
var _saved_bg_mode: int = 0
var _saved_bg_color: Color = Color.BLACK
var _saved_fog: bool = false
var _saved_vol_fog: bool = false
var _hidden_for_reveal: Array[Node] = []


func _ready() -> void:
	body_entered.connect(func(b): if b.is_in_group("Boat") or b.name == "Boat": is_boat_near = true)
	body_exited.connect(_on_body_exited)
	_build_fade()
	if memory_content:
		memory_content.dissolve_finished.connect(_on_dissolve_finished)
		if memory_content.has_signal("exploration_ended"):
			memory_content.exploration_ended.connect(_on_exploration_ended)


func _on_body_exited(b: Node) -> void:
	if b.is_in_group("Boat") or b.name == "Boat":
		is_boat_near = false
		# 动画播完前不切回；未开始消雾则可离开特写。
		if _engaged and not is_cleared and not _locking and not _session_done:
			_return_to_boat()


func _build_fade() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 100
	add_child(layer)
	_fade = ColorRect.new()
	_fade.color = Color(0, 0, 0, 0)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(_fade)


func _unhandled_input(event: InputEvent) -> void:
	# 测试：点击切入特写；已在特写且雾未散时，再点一次消雾。
	if event is InputEventMouseButton \
			and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		if _session_done or _locking:
			return
		if is_boat_near and not _engaged:
			_engage_closeup()
			get_viewport().set_input_as_handled()
		elif _engaged and not is_cleared:
			trigger_dispel()
			get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	# 空格：无摄像头时也可测试（会先切特写再消雾）。
	if is_boat_near and not is_cleared and not _session_done and not _locking:
		if Input.is_action_just_pressed("ui_accept"):
			_dispel_from_input(true)
			return

	if _locking or _session_done:
		return

	# 二次交互阶段：检测到手再显示骨架。
	if _exploring:
		var hand_now := (
			not HandTracking.right_hand.is_empty() or not HandTracking.left_hand.is_empty()
		)
		if hand_now:
			_hand_timer += delta
			if _hand_timer >= hand_stable_sec and hand_skeleton:
				hand_skeleton.set_mode("full")
		else:
			_hand_timer = 0.0
			if hand_skeleton:
				hand_skeleton.set_mode("hidden")
		return

	if is_cleared:
		return
	if not is_boat_near:
		_hand_timer = 0.0
		return

	var has_hand := (
		not HandTracking.right_hand.is_empty() or not HandTracking.left_hand.is_empty()
	)
	if has_hand:
		_hand_timer += delta
		if not _engaged and _hand_timer >= hand_stable_sec:
			_engage_closeup()
	else:
		_hand_timer = 0.0


## 公开接口：供外部手势识别、传感器信号或按键统一调用
func trigger_dispel() -> void:
	_dispel_from_input(false)


func _dispel_from_input(force_engage: bool) -> void:
	if not is_boat_near or is_cleared or _session_done or _locking:
		return
	if not _engaged:
		if not force_engage:
			return
		await _engage_closeup()
	clear_memory_fog_gentle()


func clear_memory_fog_gentle() -> void:
	is_cleared = true
	_locking = true
	if hand_skeleton and hand_skeleton.has_method("set_mode"):
		hand_skeleton.set_mode("hidden")

	var mat = memory_fog_volume.material as ShaderMaterial
	if mat == null:
		_locking = false
		return

	var tween = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.tween_method(func(val: float):
		mat.set_shader_parameter("dissolve_factor", val)
	, 1.0, 0.0, 2.0)
	await tween.finished

	if memory_fog_volume:
		memory_fog_volume.visible = false

	# 黑场淡入与插画显现同时开始；全黑时再静默切黑底，然后淡出。
	var reveal_done := false
	if memory_content and memory_content.has_signal("reveal_finished"):
		memory_content.reveal_finished.connect(
			func() -> void: reveal_done = true,
			CONNECT_ONE_SHOT
		)

	_fade.color.a = 0.0
	var fade_in := create_tween()
	fade_in.tween_property(_fade, "color:a", 1.0, fade_seconds)
	if memory_content and memory_content.has_method("reveal_memory"):
		memory_content.reveal_memory()
	await fade_in.finished

	_begin_reveal_blackout()
	await _fade_to(0.0)

	if memory_content and not reveal_done:
		await memory_content.reveal_finished

	_exploring = true
	_hand_timer = 0.0
	_locking = false


func _engage_closeup() -> void:
	if _engaged or boat_camera == null or closeup_camera == null:
		return
	_engaged = true
	_locking = true
	if boat:
		boat.visible = false
	await _fade_switch(boat_camera, closeup_camera)
	if hand_skeleton and hand_skeleton.has_method("set_mode"):
		hand_skeleton.set_mode("full")
	_locking = false


func _return_to_boat() -> void:
	if not _engaged or boat_camera == null or closeup_camera == null:
		_engaged = false
		_end_reveal_blackout()
		if boat:
			boat.visible = true
		return
	_locking = true
	_exploring = false
	if hand_skeleton and hand_skeleton.has_method("set_mode"):
		hand_skeleton.set_mode("hidden")

	await _fade_to(1.0)
	_end_reveal_blackout()
	closeup_camera.current = false
	boat_camera.current = true
	if boat:
		boat.visible = true
	await _fade_to(0.0)

	_engaged = false
	_locking = false


func _fade_to(alpha: float) -> void:
	var tw := create_tween()
	tw.tween_property(_fade, "color:a", alpha, fade_seconds)
	await tw.finished


func _fade_switch(from_cam: Camera3D, to_cam: Camera3D) -> void:
	await _fade_to(1.0)
	from_cam.current = false
	to_cam.current = true
	await _fade_to(0.0)


func _begin_reveal_blackout() -> void:
	_end_reveal_blackout()
	var map := get_tree().current_scene
	if map == null:
		return

	var env_node := map.get_node_or_null("WorldEnvironment") as WorldEnvironment
	if env_node and env_node.environment:
		_env = env_node.environment
		_saved_bg_mode = _env.background_mode
		_saved_bg_color = _env.background_color
		_saved_fog = _env.fog_enabled
		_saved_vol_fog = _env.volumetric_fog_enabled
		_env.background_mode = Environment.BG_COLOR
		_env.background_color = Color.BLACK
		_env.fog_enabled = false
		_env.volumetric_fog_enabled = false

	for child in map.get_children():
		if child.name in ["WorldEnvironment", "DirectionalLight3D", "HandSkeletonHUD", "WaveDetector"]:
			continue
		if child == boat:
			continue
		if child.name == "Rock1":
			for part in child.get_children():
				# 保留 MemoryContent / Area3D；藏岩石网格与雾体积。
				if part.name.begins_with("Rock Forms") or part is FogVolume:
					if part.visible:
						_hidden_for_reveal.append(part)
						part.visible = false
			continue
		if child.visible:
			_hidden_for_reveal.append(child)
			child.visible = false


func _end_reveal_blackout() -> void:
	for node in _hidden_for_reveal:
		if is_instance_valid(node):
			node.visible = true
	_hidden_for_reveal.clear()
	if _env:
		_env.background_mode = _saved_bg_mode
		_env.background_color = _saved_bg_color
		_env.fog_enabled = _saved_fog
		_env.volumetric_fog_enabled = _saved_vol_fog
		_env = null


func _on_exploration_ended() -> void:
	_exploring = false
	_hand_timer = 0.0
	if hand_skeleton and hand_skeleton.has_method("set_mode"):
		hand_skeleton.set_mode("hidden")


func _on_dissolve_finished() -> void:
	_session_done = true
	await _return_to_boat()
