extends Node3D

signal exploration_ended
signal reveal_started
signal reveal_finished
signal dissolve_finished

## 主场景用外部 FogVolume 消雾时设为 true，跳过自身 FogVolume 动画。
## When clearing fog in the main scene using an external FogVolume, skip the FogVolume's own animation.
@export var use_external_fog: bool = false
@export var ambient_audio: AudioStream
@export_range(-40.0, 6.0) var ambient_volume_db: float = -12.0
@export_group("Picture Layout")
## Position of the illustration relative to MemoryContent
@export var picture_offset: Vector3 = Vector3(0, -0.6384554, 0):
	set(value):
		picture_offset = value
		if is_node_ready() and memory_layers:
			memory_layers.position = picture_offset
## The proportion of the illustration relative to the height of the close-up frame
@export_range(0.4, 1.0, 0.01) var screen_fill: float = 0.85:
	set(value):
		screen_fill = value
		if is_node_ready():
			_apply_picture_size()
@export_group("")
@export_range(0.1, 10.0, 0.1) var reveal_duration: float = 3.5
@export_range(0.0, 3.0, 0.05) var reveal_delay: float = 0.1
@export_range(0.1, 10.0, 0.1) var dissolve_duration: float = 3.0
@export_range(0.1, 10.0, 0.1) var fog_fade_duration: float = 2.2

enum MemoryState { FOG, REVEALING, EXPLORING, DISSOLVING, FINISHED }
var state: MemoryState = MemoryState.FOG

const DISSOLVE_SHADER = preload("res://Shaders/memory_dissolve.gdshader")
const PICTURE_ASPECT := 4.0 / 3.0

@onready var memory_layers: Node3D = $Memorylayers
@onready var memory_fog: Area3D = $MemoryFog
@onready var fog_visual: FogVolume = $MemoryFog/FogVisual

var picture_layers: Array[MeshInstance3D] = []
var memory_ready: bool = false
var _audio: AudioStreamPlayer


func _ready() -> void:
	_audio = AudioStreamPlayer.new()
	_audio.stream = ambient_audio
	_audio.volume_db = ambient_volume_db
	add_child(_audio)
	
	for child in memory_layers.get_children():
		if child is MeshInstance3D:
			picture_layers.append(child)
			child.material_override = _make_dissolve_material(child)
			# Visibility is animated by the dissolve shader.
			child.transparency = 0.0
			child.material_override.set_shader_parameter("progress", 1.0)

	memory_layers.position = picture_offset
	_apply_picture_size()

	memory_layers.hide()
	get_viewport().physics_object_picking = true
	if use_external_fog:
		memory_fog.hide()
		memory_fog.input_ray_pickable = false
	else:
		memory_fog.show()
		fog_visual.material = fog_visual.material.duplicate()
		fog_visual.material.set_shader_parameter("fog_opacity", 1.0)
		memory_fog.input_ray_pickable = true
		memory_fog.input_event.connect(_on_fog_input_event)


func _apply_picture_size() -> void:
	if picture_layers.is_empty():
		return
	var cam := get_node_or_null("CloseupCamera") as Camera3D
	var distance := 3.14
	if cam:
		distance = absf(cam.position.z - picture_offset.z)
		distance = maxf(distance, 0.2)
	var half_fov := deg_to_rad(cam.fov if cam else 75.0) * 0.5
	var height := screen_fill * 2.0 * distance * tan(half_fov)
	var width := height * PICTURE_ASPECT
	var size := Vector2(width, height)
	for layer in picture_layers:
		var mesh := layer.mesh
		if mesh is QuadMesh:
			(mesh as QuadMesh).size = size
		elif mesh is PlaneMesh:
			(mesh as PlaneMesh).size = size


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

	# Image without noise settings can still be dissolved normally
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


# 鼠标与未来的手势确认都调用这个入口，每次确认只调用一次
# Both mouse clicks and gesture recognition call this entry point;
# it is called only once per confirmation.
func interact() -> void:
	match state:
		MemoryState.FOG:
			if use_external_fog:
				return
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
# Collision Boxes That Do Not Depend on the Foreground
func _pointer_over_picture(screen_position: Vector2) -> bool:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return false
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

	if not use_external_fog:
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
	await _after_picture_revealed()
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
	_add_dissolve_animation(tween)
	await tween.finished
	memory_layers.hide()
	state = MemoryState.FINISHED
	dissolve_finished.emit()


func _after_picture_revealed() -> void:
	if ambient_audio:
		_audio.play()


func _add_dissolve_animation(tween: Tween) -> void:
	if _audio.playing:
		tween.tween_property(_audio, "volume_db", -60.0, dissolve_duration)
		tween.finished.connect(_audio.stop)
