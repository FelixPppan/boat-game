extends Node3D
# Move a block with your hand. Pinch thumb and index finger to grab it.
# Only the first hand that shows up is used, until it leaves the picture.

const PINCH_START: float = 0.35
const PINCH_END: float = 0.65
const RELEASE_DELAY: float = 0.25
const LOST_DELAY: float = 0.25
const GRAB_RADIUS: float = 1.0
const FOLLOW_SPEED: float = 40.0

@export var camera: Camera3D
@export var block: Node3D
@export var cursor: Node3D
@export var pickupSound: FmodEventEmitter3D

var _main_side: String = ""
var _grabbing: bool = false
var _grab_offset: Vector3 = Vector3.ZERO
var _lost_timer: float = 0.0
var _release_timer: float = 0.0


func _process(delta: float) -> void:
	if not camera.is_current():
		_main_side = ""
		_grabbing = false
		cursor.visible = false
		return

	_update_main_side(delta)

	var pos := _hand_position(_main_side)
	cursor.visible = pos.is_finite()
	if not pos.is_finite():
		return
	cursor.global_position = pos

	var pinch := HandTracking.get_pinch_ratio(HandTracking.get_hand(_main_side))
	if _grabbing:
		_hold_block(pos, pinch, delta)
	elif pinch < PINCH_START and pos.distance_to(block.global_position) < GRAB_RADIUS:
		_grabbing = true
		_grab_offset = block.global_position - pos
		_release_timer = 0.0
		pickupSound.play_one_shot()


# The first hand in the picture becomes the main hand and stays it until it has been gone for a moment
func _update_main_side(delta: float) -> void:
	if _main_side == "":
		if not HandTracking.right_hand.is_empty():
			_main_side = "right"
		elif not HandTracking.left_hand.is_empty():
			_main_side = "left"
		_lost_timer = 0.0
		return

	if HandTracking.get_hand(_main_side).is_empty():
		_lost_timer += delta
		if _lost_timer > LOST_DELAY:
			_main_side = ""
			_grabbing = false
	else:
		_lost_timer = 0.0


func _hold_block(pos: Vector3, pinch: float, delta: float) -> void:
	var weight := 1.0 - exp(-FOLLOW_SPEED * delta)
	block.global_position = block.global_position.lerp(pos + _grab_offset, weight)

	# Tracking can glitch for a few frames when the hand moves fast,
	# so only let go once the fingers have been open for a moment
	if pinch > PINCH_END:
		_release_timer += delta
		if _release_timer > RELEASE_DELAY:
			_grabbing = false
	else:
		_release_timer = 0.0


# Where the pinch point of a hand is on the block's plane, or Vector3.INF if there is no hand
func _hand_position(side: String) -> Vector3:
	var hand := HandTracking.get_hand(side)
	if hand.is_empty():
		return Vector3.INF

	var pinch_point := HandTracking.get_pinch_point(hand)
	var screen_pos := HandTracking.to_screen(pinch_point, get_viewport().get_visible_rect().size)
	var origin := camera.project_ray_origin(screen_pos)
	var direction := camera.project_ray_normal(screen_pos)

	var plane := Plane(Vector3.UP, block.global_position.y)
	var hit = plane.intersects_ray(origin, direction)
	return hit if hit != null else Vector3.INF
