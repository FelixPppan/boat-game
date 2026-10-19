extends Node
## Either hand can reveal or dismiss a memory; each phase starts a fresh gesture.
@export var min_swing: float = 0.07
@export var swings_needed: int = 2
@export var wave_window: float = 1.8

var _time := 0.0
var _hands: Dictionary = {}
var _target: Node
var _phase := 0

func _process(delta: float) -> void:
	_time += delta
	var target: Node = null
	var phase := 0
	for trigger in get_tree().get_nodes_in_group("memory_triggers"):
		phase = trigger.get_wave_phase()
		if phase != 0:
			target = trigger
			break
	if target != _target or phase != _phase:
		_hands.clear()
		_target = target
		_phase = phase
	if target == null:
		return
	for side in ["left", "right"]:
		var hand := HandTracking.get_hand(side)
		if hand.is_empty():
			_hands.erase(side)
			continue
		if _sample(side, hand[HandTracking.MIDDLE_MCP].x, _time):
			target.handle_wave()
			_hands.clear()
			return

func _sample(side: String, x: float, now: float) -> bool:
	if not _hands.has(side):
		_hands[side] = {"direction": 0, "extreme": x, "turns": []}
		return false
	var motion: Dictionary = _hands[side]
	var turns: Array = motion.turns
	while not turns.is_empty() and now - turns[0] > wave_window:
		turns.pop_front()
	var moved: float = x - motion.extreme
	if motion.direction == 0:
		if absf(moved) >= min_swing:
			motion.direction = signf(moved)
			motion.extreme = x
	elif moved * motion.direction > 0.0:
		motion.extreme = x
	elif absf(moved) >= min_swing:
		motion.direction = -motion.direction
		motion.extreme = x
		turns.append(now)
	return turns.size() >= swings_needed
