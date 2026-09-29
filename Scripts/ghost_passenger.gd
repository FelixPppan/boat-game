extends Node3D

# Assign the imported player after the animated model is available.
@export var animation_player: AnimationPlayer
@export var idle_animation: StringName = &"idle"
@export var forward_animation: StringName = &"row_forward"
# A forward stroke on the opposite side turns the boat.
@export var left_turn_animation: StringName = &"row_right"
@export var right_turn_animation: StringName = &"row_left"
@export var blend_time: float = 0.2

func _ready() -> void:
	if animation_player == null:
		return
	get_parent().rowing_animation_changed.connect(_play_action)
	_play_action(&"idle")

func _play_action(action: StringName) -> void:
	var clip: StringName = idle_animation
	match action:
		&"forward": clip = forward_animation
		&"left": clip = left_turn_animation
		&"right": clip = right_turn_animation
	animation_player.play(clip, blend_time)
