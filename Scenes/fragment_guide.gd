extends Node
# Plays one chime at a time to guide the player to the next big memory
# fragment. Stops a fragment's chime as soon as the boat enters its Area3D,
# and also pauses the chime while the player is interacting with any
# memory trigger (so it doesn't play under a closeup view or small pickup).

@export var triggers: Array[Area3D] = []
@export var chimes: Array[FmodEventEmitter3D] = []

var _index: int = 0
var _suppressed: bool = false


func _ready() -> void:
	for i in triggers.size():
		triggers[i].body_entered.connect(_on_body_entered.bind(i))

	if not chimes.is_empty():
		chimes[0].play()


func _process(_delta: float) -> void:
	if _index >= chimes.size():
		return  # every big fragment has been reached

	var someone_engaged := false
	for trigger in get_tree().get_nodes_in_group("memory_triggers"):
		if trigger.get("_engaged"):
			someone_engaged = true
			break

	if someone_engaged and not _suppressed:
		_suppressed = true
		chimes[_index].stop()
	elif not someone_engaged and _suppressed:
		_suppressed = false
		chimes[_index].play()


func _on_body_entered(body: Node3D, i: int) -> void:
	if i != _index or body != triggers[i].boat:
		return

	chimes[i].stop()
	_suppressed = false
	_index += 1
	if _index < chimes.size():
		chimes[_index].play()
