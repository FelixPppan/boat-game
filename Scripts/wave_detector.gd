extends Node
# Detects a waving hand and tells the fog to dissolve.

const MIN_SWING: float = 0.05  # sideways distance that counts as a swing (0.05 = 5% of the image width)
const SWINGS_NEEDED: int = 3
const WINDOW: float = 1.0  # the swings must happen within this many seconds

@export var fog_remover: Node  # the node with memory_fog_remove.gd

var _direction: int = 0  # -1 moving left, 1 moving right, 0 not moving yet
var _extreme_x: float = 0.0  # furthest x reached in the current direction
var _swing_times: Array[float] = []

func _process(_delta: float) -> void:
	var hand := HandTracking.get_hand("right")
	if hand.is_empty():
		hand = HandTracking.get_hand("left")
	if hand.is_empty():
		_reset()
		return

	var x := hand[HandTracking.MIDDLE_MCP].x
	var moved := x - _extreme_x

	if _direction == 0:
		if absf(moved) > MIN_SWING:
			_direction = 1 if moved > 0.0 else -1
			_extreme_x = x
	elif moved * _direction > 0.0:
		# still moving the same way, follow the hand
		_extreme_x = x
	elif absf(moved) > MIN_SWING:
		# moved back far enough, that is one swing
		_direction = -_direction
		_extreme_x = x
		_swing_times.append(Time.get_ticks_msec() / 1000.0)
	_check_wave()

func _check_wave() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	while not _swing_times.is_empty() and now - _swing_times[0] > WINDOW:
		_swing_times.pop_front()

	if _swing_times.size() >= SWINGS_NEEDED:
		fog_remover.trigger_dispel()
		_reset()

func _reset() -> void:
	_direction = 0
	_swing_times.clear()
