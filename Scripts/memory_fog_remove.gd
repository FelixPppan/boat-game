extends Area3D

signal interaction_finished

@export var memory_fog_volume: FogVolume
@export var memory_content: Node3D
@export var overlay: SubViewportContainer
@export var hand_skeleton: Node
@export var boat: Node3D
@export var boat_camera: Camera3D
@export var closeup_camera: Camera3D
@export var view_point: Marker3D
@export var first_person_hands: CanvasLayer
@export var hand_stable_sec: float = 0.25
@export var white_mist: TextureRect
## If true, block engage / fog clear until every level_target is done (e.g. 3/3).
@export var require_all_levels: bool = false

var is_boat_near := false
var is_cleared := false
var _engaged := false
var _session_done := false
var _locking := false
var _exploring := false
var _hand_timer := 0.0
var _boat_process_mode: int
var _boat_was_visible: bool
var _wait_for_hand_release := false


func _ready() -> void:
	add_to_group("memory_triggers")
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	memory_content.exploration_ended.connect(_on_exploration_ended)
	memory_content.dissolve_finished.connect(_on_dissolve_finished)
	memory_fog_volume.material = memory_fog_volume.material.duplicate()
	overlay.hide()
	white_mist.modulate.a = 0.0


func _on_body_entered(body: Node) -> void:
	if body == boat:
		is_boat_near = true


func _on_body_exited(body: Node) -> void:
	if body == boat:
		is_boat_near = false


func _unhandled_input(event: InputEvent) -> void:
	if _engaged and not is_cleared and event.is_action_pressed("ui_cancel"):
		_wait_for_hand_release = true
		_hand_timer = 0.0
		_leave_closeup()
		get_viewport().set_input_as_handled()
		return
	if (not is_boat_near and not _engaged) or _session_done or _locking or is_cleared:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if _engaged:
			trigger_dispel()
		else:
			_engage()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_accept"):
		if not _engaged:
			_engage()
		trigger_dispel()
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if _session_done or _locking or (not is_boat_near and not _engaged):
		return
	var has_hand := not HandTracking.right_hand.is_empty() or not HandTracking.left_hand.is_empty()
	if not has_hand:
		_wait_for_hand_release = false
	_hand_timer = _hand_timer + delta if has_hand else 0.0
	if _exploring:
		hand_skeleton.set_mode("hidden")
	elif not _engaged and not _wait_for_hand_release and _hand_timer >= hand_stable_sec:
		_engage()


func _can_interact() -> bool:
	if get_tree().get_first_node_in_group("memory_cinematic") != null:
		return false
	if not require_all_levels:
		return true
	for t in get_tree().get_nodes_in_group("level_target"):
		if not t._done:
			return false
	return true


func _engage() -> void:
	if not _can_interact():
		return
	# Only one memory may own the boat and the overlay interaction at a time.
	for trigger in get_tree().get_nodes_in_group("memory_triggers"):
		if trigger != self and trigger._engaged:
			return
	_engaged = true
	_boat_process_mode = boat.process_mode
	# GhostSeat is a child of the boat, so hiding the boat hides both models.
	# First-person hands live outside this hierarchy and remain visible.
	_boat_was_visible = boat.visible
	boat.hide()
	boat.process_mode = Node.PROCESS_MODE_DISABLED
	closeup_camera.global_transform = view_point.global_transform
	closeup_camera.make_current()
	first_person_hands.set_active(true)
	hand_skeleton.set_mode("hidden")


# 0: ignore gestures during transitions; 1: wave clears fog; 2: thumbs-up dismisses the picture.
func get_wave_phase() -> int:
	if not _can_interact():
		return 0
	if not _engaged or _locking or _session_done:
		return 0
	if _exploring:
		return 2
	return 0 if is_cleared else 1


func handle_wave() -> void:
	if get_wave_phase() == 1:
		trigger_dispel()


func confirm_memory() -> void:
	if get_wave_phase() == 2:
		memory_content.dissolve_memory()


func trigger_dispel() -> void:
	if not _engaged or is_cleared or _locking or _session_done:
		return
	is_cleared = true
	_locking = true
	hand_skeleton.set_mode("hidden")
	var tween := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(memory_fog_volume.material, "shader_parameter/dissolve_factor", 0.0, 2.0)
	await tween.finished
	memory_fog_volume.hide()
	overlay.show()
	var mist_tween := create_tween()
	mist_tween.tween_property(white_mist, "modulate:a", 0.9, 1.2)
	await memory_content.reveal_memory()
	_exploring = true
	_hand_timer = 0.0
	_locking = false


func _on_exploration_ended() -> void:
	_exploring = false
	hand_skeleton.set_mode("hidden")
	var mist_tween := create_tween()
	mist_tween.tween_property(white_mist, "modulate:a", 0.0, 3.0)


func _on_dissolve_finished() -> void:
	if _session_done:
		return
	overlay.hide()
	_session_done = true
	_leave_closeup()
	interaction_finished.emit()


func _leave_closeup() -> void:
	hand_skeleton.set_mode("hidden")
	boat_camera.make_current()
	first_person_hands.set_active(false)
	boat.visible = _boat_was_visible
	boat.process_mode = _boat_process_mode
	_engaged = false
