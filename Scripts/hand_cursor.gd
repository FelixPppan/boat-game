extends Node3D
# Move a block with your hand. Pinch thumb and index finger to grab it.
# The hand that grabs the block keeps it until it lets go.
const PINCH_START: float = 0.35
const PINCH_END: float = 0.65
const RELEASE_DELAY: float = 0.25
const GRAB_RADIUS: float = 1.0
const FOLLOW_SPEED: float = 40.0

@export var camera: Camera3D
@export var block: Node3D
@export var cursor: Node3D

var _grab_side: String = ""
var _grab_offset: Vector3 = Vector3.ZERO
var _release_timer: float = 0.0

func _process(delta: float) -> void:
	if not camera.is_current():
		_grab_side = ""
		cursor.visible = false
	elif _grab_side == "":
		_look_for_grab()
	else:
		_hold_block(delta)

# Nobody is holding the block, so the hand closest to it can grab it
func _look_for_grab() -> void:
	var nearest_side := ""
	var nearest_pos := Vector3.ZERO
	var nearest_distance := INF

	for side in ["right", "left"]:
		var pos := _hand_position(side)
		if not pos.is_finite():
			continue

		var distance := pos.distance_to(block.global_position)
		if distance < nearest_distance:
			nearest_side = side
			nearest_pos = pos
			nearest_distance = distance

	cursor.visible = nearest_side != ""
	if nearest_side == "":
		return

	cursor.global_position = nearest_pos

	var pinch := HandTracking.get_pinch_ratio(HandTracking.get_hand(nearest_side))
	if pinch < PINCH_START and nearest_distance < GRAB_RADIUS:
		_grab_side = nearest_side
		_grab_offset = block.global_position - nearest_pos
		_release_timer = 0.0

# One hand is holding the block, the other hand is ignored
func _hold_block(delta: float) -> void:
	var pos := _hand_position(_grab_side)
	var hand_visible := pos.is_finite()
	cursor.visible = hand_visible

	var letting_go := true
	if hand_visible:
		var pinch := HandTracking.get_pinch_ratio(HandTracking.get_hand(_grab_side))
		letting_go = pinch > PINCH_END

		cursor.global_position = pos
		var weight := 1.0 - exp(-FOLLOW_SPEED * delta)
		block.global_position = block.global_position.lerp(pos + _grab_offset, weight)

	# Tracking can glitch for a few frames when the hand moves fast,
	# so only let go once the grab has been broken for a moment
	if letting_go:
		_release_timer += delta
		if _release_timer > RELEASE_DELAY:
			_grab_side = ""
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
