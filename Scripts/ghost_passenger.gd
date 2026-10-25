extends Node3D

# Assign the imported player after the animated model is available.
@export var animation_player: AnimationPlayer
@export var idle_animation: StringName = &"idle"
@export var forward_animation: StringName = &"row_forward"
# A forward stroke on the opposite side turns the boat.
@export var left_turn_animation: StringName = &"row_right"
@export var right_turn_animation: StringName = &"row_left"
@export var blend_time: float = 0.2

# The ghost model is mirrored across the boat's centreline so its oar is on the
# same side as the player's real oar.
# 幽灵模型沿船的中心线镜像,让它的桨和玩家手里真实的桨在同一侧。
@export var model: Node3D
## Side the oar is on in the unmirrored model: +1 left (port), -1 right (starboard).
## 模型未镜像时桨在哪一侧:+1 左舷,-1 右舷。
@export_enum("Right:-1", "Left:1") var model_oar_side: int = -1

var _model_rest: Transform3D
var _mirror: Transform3D
var _mirrored := false


func _ready() -> void:
	if model != null:
		_model_rest = model.transform
		# Mirror across the boat's YZ plane, expressed in this node's rest frame.
		# 船体 YZ 平面的镜像,换算到本节点的静止坐标系里。
		var flip_x := Transform3D(Basis.from_scale(Vector3(-1.0, 1.0, 1.0)), Vector3.ZERO)
		_mirror = transform.affine_inverse() * flip_x * transform
	if animation_player == null:
		return
	get_parent().rowing_animation_changed.connect(_play_action)
	_play_action(&"idle")


func _process(_delta: float) -> void:
	if model == null or not get_parent().has_method("oar_side"):
		return
	var side: float = get_parent().oar_side()
	if side == 0.0:
		return
	var mirrored := signf(side) != float(model_oar_side)
	if mirrored != _mirrored:
		_mirrored = mirrored
		model.transform = _mirror * _model_rest if mirrored else _model_rest


func _play_action(action: StringName) -> void:
	var clip: StringName = idle_animation
	match action:
		&"forward": clip = forward_animation
		&"left": clip = left_turn_animation
		&"right": clip = right_turn_animation
	animation_player.play(clip, blend_time)
