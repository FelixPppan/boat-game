extends Node3D

@export var rise_duration: float = 5.0
@export var water_height: float = 0.0
@export var clearance: float = 0.2
@export var upright_rotation: Vector3 = Vector3.ZERO
@export var rumble_sound: FmodEventEmitter3D

var _emerged := false


func _ready() -> void:
	_connect_levels.call_deferred()


func _connect_levels() -> void:
	for target in get_tree().get_nodes_in_group("level_target"):
		target.collected.connect(_on_level_completed)


func _on_level_completed() -> void:
	if _emerged:
		return
	for target in get_tree().get_nodes_in_group("level_target"):
		if not target._done:
			return
	_emerged = true
	rumble_sound.play()
	var upright_basis := Basis.from_euler(upright_rotation * PI / 180.0).scaled(scale)
	var final_transform := get_parent_node_3d().global_transform * Transform3D(upright_basis, position)
	var bottom := _mesh_bottom(self, final_transform)
	var lift := maxf(0.0, water_height + clearance - bottom)
	var destination := global_position + Vector3.UP * lift
	var tween := create_tween().set_parallel(true)
	tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(self, "rotation_degrees", upright_rotation, rise_duration)
	tween.tween_property(self, "global_position", destination, rise_duration)


func _mesh_bottom(node: Node3D, world: Transform3D) -> float:
	var bottom := INF
	if node is MeshInstance3D:
		bottom = (world * node.get_aabb()).position.y
	for child in node.get_children():
		if child is Node3D:
			bottom = minf(bottom, _mesh_bottom(child, world * child.transform))
	return bottom
