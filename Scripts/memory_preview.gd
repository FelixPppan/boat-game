extends Node3D

signal exploration_ended
signal reveal_started
signal reveal_finished

@export_range(0.1, 10.0, 0.1) var reveal_duration: float = 3.5
@export_range(0.0, 3.0, 0.05) var reveal_delay: float = 0.1
@export_range(0.1, 10.0, 0.1) var dissolve_duration: float = 3.0
@export_range(0.1, 10.0, 0.1) var fog_fade_duration: float = 2.2

enum MemoryState { FOG, REVEALING, EXPLORING, DISSOLVING, FINISHED }
var state: MemoryState = MemoryState.FOG

const DISSOLVE_SHADER = preload("res://Shaders/memory_dissolve.gdshader")

@onready var memory_layers: Node3D = $Memorylayers
@onready var memory_fog: Area3D = $MemoryFog
@onready var fog_visual: FogVolume = $MemoryFog/FogVisual

var picture_layers: Array[MeshInstance3D] = []
var memory_ready: bool = false


func _ready() -> void:
	# 为每层建立独立的运行时材质，不修改编辑器中的原材质。
	for child in memory_layers.get_children():
		if child is MeshInstance3D:
			picture_layers.append(child)
			child.material_override = _make_dissolve_material(child)
			child.transparency = 0.0
			child.material_override.set_shader_parameter("progress", 1.0)

	memory_layers.hide()
	memory_fog.show()
	fog_visual.material = fog_visual.material.duplicate()
	fog_visual.material.set_shader_parameter("fog_opacity", 1.0)

	# 允许鼠标检测，并在代码里连接点击信号。
	get_viewport().physics_object_picking = true
	memory_fog.input_ray_pickable = true
	memory_fog.input_event.connect(_on_fog_input_event)


func _make_dissolve_material(layer: MeshInstance3D) -> ShaderMaterial:
	var original := layer.get_active_material(0)
	var material: ShaderMaterial
	if original is ShaderMaterial and original.shader == DISSOLVE_SHADER:
		material = original.duplicate() as ShaderMaterial
	else:
		material = ShaderMaterial.new()
		material.shader = DISSOLVE_SHADER
		if original is BaseMaterial3D:
			material.set_shader_parameter("picture", original.albedo_texture)

	# 尚未设置噪声的图片层也能正常溶解。
	if material.get_shader_parameter("noise_texture") == null:
		var noise := FastNoiseLite.new()
		noise.frequency = 0.015
		var texture := NoiseTexture2D.new()
		texture.width = 256
		texture.height = 256
		texture.seamless = true
		texture.noise = noise
		material.set_shader_parameter("noise_texture", texture)
	return material


func _on_fog_input_event(
	_camera: Node,
	event: InputEvent,
	_position: Vector3,
	_normal: Vector3,
	_shape_idx: int
) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			interact()


# 鼠标与未来的手势确认都调用这个入口，每次确认只调用一次。
func interact() -> void:
	match state:
		MemoryState.FOG:
			reveal_memory()
		MemoryState.EXPLORING:
			dissolve_memory()


func _unhandled_input(event: InputEvent) -> void:
	if state != MemoryState.EXPLORING:
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			if _pointer_over_picture(event.position):
				get_viewport().set_input_as_handled()
				interact()


# 检查图片矩形范围，随图层移动，不依赖前景的停留碰撞盒。
func _pointer_over_picture(screen_position: Vector2) -> bool:
	var camera: Camera3D = $Camera3D
	var origin := camera.project_ray_origin(screen_position)
	var direction := camera.project_ray_normal(screen_position)
	for layer in picture_layers:
		var local_origin := layer.to_local(origin)
		var local_direction := layer.global_transform.basis.inverse() * direction
		if absf(local_direction.z) < 0.00001:
			continue
		var distance := -local_origin.z / local_direction.z
		if distance < 0.0:
			continue
		var hit := local_origin + local_direction * distance
		var bounds := layer.mesh.get_aabb()
		if (hit.x >= bounds.position.x and hit.x <= bounds.end.x
				and hit.y >= bounds.position.y and hit.y <= bounds.end.y):
			return true
	return false


func reveal_memory() -> void:
	# 防止连续点击，重复播放动画。
	if state != MemoryState.FOG:
		return

	state = MemoryState.REVEALING
	memory_fog.input_ray_pickable = false
	memory_layers.show()
	await $MemoryParticles.play(picture_layers, true)
	reveal_started.emit()

	# 所有动画同时进行。
	var tween := create_tween()
	tween.set_parallel(true)
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_IN_OUT)

	# 雾气逐渐透明，并稍微向外散开。
	tween.tween_property(fog_visual.material, "shader_parameter/fog_opacity", 0.0, fog_fade_duration)
	tween.tween_property(
		fog_visual, "size", fog_visual.size * 1.15, fog_fade_duration
	)

	# 溶解进度从 1（消失）倒放到 0（完整），形成凝聚效果。
	for layer in picture_layers:
		var material := layer.material_override as ShaderMaterial
		tween.tween_property(
			material, "shader_parameter/progress", 0.0, reveal_duration
		).set_delay(reveal_delay)

	await tween.finished

	memory_fog.hide()
	state = MemoryState.EXPLORING
	memory_ready = true
	reveal_finished.emit()


func dissolve_memory() -> void:
	if state != MemoryState.EXPLORING:
		return
	state = MemoryState.DISSOLVING
	memory_ready = false
	exploration_ended.emit()
	await $MemoryParticles.play(picture_layers, false)

	var tween := create_tween()
	tween.set_parallel(true)
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_IN_OUT)
	for layer in picture_layers:
		var material := layer.material_override as ShaderMaterial
		tween.tween_property(
			material, "shader_parameter/progress", 1.0, dissolve_duration
		)
	await tween.finished
	memory_layers.hide()
	state = MemoryState.FINISHED
