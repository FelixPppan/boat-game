extends CharacterBody3D

@export var speed: float = 8.0
@export var turn_speed: float = 2.0

func _physics_process(delta: float) -> void:
	
	var rotation_input = Input.get_action_strength("ui_left") - Input.get_action_strength("ui_right")
	if Input.is_key_pressed(KEY_A):
		rotate_y(turn_speed * delta)
	if Input.is_key_pressed(KEY_D):
		rotate_y(-turn_speed * delta)
	
	var forward_input = 0.0
	if Input.is_key_pressed(KEY_W):
		forward_input += 1.0
	if Input.is_key_pressed(KEY_S):
		forward_input -= 1.0
		
	var forward_dir = -transform.basis.z
	velocity = forward_dir * forward_input * speed
	
	move_and_slide()
	
	if is_on_wall():
		velocity = Vector3.ZERO
