extends Node
## Holding a thumbs-up with either hand dismisses the revealed memory picture.
@export var hold_sec: float = 0.4

var _target: Node
var _timer := 0.0

func _process(delta: float) -> void:
	var target: Node = null
	for trigger in get_tree().get_nodes_in_group("memory_triggers"):
		if trigger.get_wave_phase() == 2:
			target = trigger
			break
	if target != _target:
		_target = target
		_timer = 0.0
	if target == null:
		return
	_timer = _timer + delta if _any_thumbs_up() else 0.0
	if _timer >= hold_sec:
		_timer = 0.0
		target.confirm_memory()

func _any_thumbs_up() -> bool:
	for side in ["left", "right"]:
		var hand := HandTracking.get_hand(side)
		if not hand.is_empty() and HandTracking.is_thumbs_up(hand):
			return true
	return false
