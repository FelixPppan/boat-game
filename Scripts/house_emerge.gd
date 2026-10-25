extends Node3D

signal reveal_finished

@export var rise_duration: float = 5.0
@export var water_height: float = 0.0
@export var clearance: float = 0.2
@export var upright_rotation: Vector3 = Vector3.ZERO
@export var reveal_camera: Camera3D
@export var boat: Node3D
@export var camera_start: Marker3D
@export var camera_via: Marker3D
@export var camera_end: Marker3D
@export var camera_transition: float = 1.0
@export var camera_hold: float = 1.0
@export var fade_duration: float = 0.35
@export var rumble_sound: FmodEventEmitter3D

var _emerged := false
var _fade: ColorRect


func _ready() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 40
	add_child(layer)
	_fade = ColorRect.new()
	_fade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_fade.color = Color(0.92, 0.94, 0.97, 0.0)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_fade)
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
	var upright_basis := Basis.from_euler(upright_rotation * PI / 180.0).scaled(scale)
	var final_transform := get_parent_node_3d().global_transform * Transform3D(upright_basis, position)
	var bottom := _mesh_bottom(self, final_transform)
	var lift := maxf(0.0, water_height + clearance - bottom)
	var destination := global_position + Vector3.UP * lift
	# Frame both the submerged and raised poses so the house stays in view.
	var bounds := _mesh_bounds(self, global_transform)
	final_transform.origin += Vector3.UP * lift
	bounds = bounds.merge(_mesh_bounds(self, final_transform))
	var focus := bounds.get_center()
	var previous_camera := get_viewport().get_camera_3d()
	var boat_mode := boat.process_mode
	add_to_group("memory_cinematic")
	boat.process_mode = Node.PROCESS_MODE_DISABLED
	await _fade_to(1.0)
	var start := camera_start.global_position
	var via := camera_via.global_position
	var end := camera_end.global_position
	_move_camera(0.0, start, via, end, focus)
	reveal_camera.make_current()
	await _fade_to(0.0)
	var move := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	move.tween_method(_move_camera.bind(start, via, end, focus), 0.0, 1.0, camera_transition)
	await move.finished
	rumble_sound.play()
	var tween := create_tween().set_parallel(true)
	tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(self, "rotation_degrees", upright_rotation, rise_duration)
	tween.tween_property(self, "global_position", destination, rise_duration)
	await tween.finished
	await get_tree().create_timer(camera_hold).timeout
	await _fade_to(1.0)
	previous_camera.make_current()
	await _fade_to(0.0)
	boat.process_mode = boat_mode
	remove_from_group("memory_cinematic")
	reveal_finished.emit()


func _move_camera(progress: float, start: Vector3, via: Vector3, end: Vector3, focus: Vector3) -> void:
	var t := progress * 2.0
	if t <= 1.0:
		reveal_camera.global_position = start.cubic_interpolate(via, start, end, t)
	else:
		reveal_camera.global_position = via.cubic_interpolate(end, start, end, t - 1.0)
	reveal_camera.look_at(focus, Vector3.UP)


func _fade_to(alpha: float) -> void:
	var tween := create_tween()
	tween.tween_property(_fade, "color:a", alpha, fade_duration)
	await tween.finished


func _mesh_bounds(node: Node3D, world: Transform3D) -> AABB:
	var bounds: Array[AABB] = []
	_collect_bounds(node, world, bounds)
	var combined := bounds[0]
	for index in range(1, bounds.size()):
		combined = combined.merge(bounds[index])
	return combined


func _collect_bounds(node: Node3D, world: Transform3D, bounds: Array[AABB]) -> void:
	if node is MeshInstance3D:
		bounds.append(world * node.get_aabb())
	for child in node.get_children():
		if child is Node3D:
			_collect_bounds(child, world * child.transform, bounds)


func _mesh_bottom(node: Node3D, world: Transform3D) -> float:
	var bottom := INF
	if node is MeshInstance3D:
		bottom = (world * node.get_aabb()).position.y
	for child in node.get_children():
		if child is Node3D:
			bottom = minf(bottom, _mesh_bottom(child, world * child.transform))
	return bottom
