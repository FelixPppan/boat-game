extends Node3D
## Small local fog patches follow the nearest point on each collision wall.
## Reuses the map's noise texture; hidden volumes do not render.

@export var boat: Node3D
@export var noise_texture: Texture3D
@export_range(1.0, 30.0) var warning_distance: float = 12.0
@export_range(0.5, 10.0) var full_distance: float = 3.0
@export var wall_height: float = 7.0
@export var patch_length: float = 28.0
@export var max_density: float = 0.85

const FOG_SHADER := preload("res://Shaders/boundary_fog.gdshader")
var _walls: Array[CollisionShape3D] = []
var _volumes: Array[FogVolume] = []
var _strengths: Array[float] = []


func _ready() -> void:
	if boat == null:
		set_process(false)
		return
	for child in get_children():
		var collision := child.get_node_or_null("CollisionShape3D") as CollisionShape3D
		if collision == null or not collision.shape is BoxShape3D:
			continue
		var material := ShaderMaterial.new()
		material.shader = FOG_SHADER
		material.set_shader_parameter("noise_texture", noise_texture)
		var volume := FogVolume.new()
		volume.name = str(child.name) + "WarningFog"
		volume.material = material
		volume.visible = false
		add_child(volume)
		_walls.append(collision)
		_volumes.append(volume)
		_strengths.append(0.0)


func _process(delta: float) -> void:
	for i in _walls.size():
		var wall := _walls[i]
		var box := wall.shape as BoxShape3D
		var local_boat := wall.to_local(boat.global_position)
		var half := box.size * 0.5
		var nearest := Vector3(clampf(local_boat.x, -half.x, half.x),
			local_boat.y, clampf(local_boat.z, -half.z, half.z))
		var distance := Vector2(local_boat.x - nearest.x, local_boat.z - nearest.z).length()
		var target := 1.0 - smoothstep(minf(full_distance, warning_distance - 0.01), warning_distance, distance)
		_strengths[i] = move_toward(_strengths[i], target, delta * 1.5)
		var volume := _volumes[i]
		volume.visible = _strengths[i] > 0.001
		if not volume.visible:
			continue
		var along_x := box.size.x > box.size.z
		var length := minf(patch_length, box.size.x if along_x else box.size.z)
		var center := Vector3.ZERO
		if along_x:
			center.x = clampf(local_boat.x, -half.x + length * 0.5, half.x - length * 0.5)
		else:
			center.z = clampf(local_boat.z, -half.z + length * 0.5, half.z - length * 0.5)
		volume.global_transform = wall.global_transform
		volume.global_position = wall.to_global(center)
		volume.global_position.y = wall.global_position.y - half.y + wall_height * 0.5
		volume.size = Vector3(length, wall_height, 3.0) if along_x else Vector3(3.0, wall_height, length)
		volume.material.set_shader_parameter("density", max_density * _strengths[i])
