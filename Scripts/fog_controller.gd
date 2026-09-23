class_name FogController
extends Node3D

@export_group("Nodes")
@export var water_fog_volume: FogVolume

var fog_material: ShaderMaterial
var debug_print_timer := 0.0

func _ready() -> void:
	if water_fog_volume and water_fog_volume.material is ShaderMaterial:
		fog_material = water_fog_volume.material as ShaderMaterial
		print("[FogController] Ready: volume=", water_fog_volume.get_path(),
			", material=", fog_material,
			", initial boat_position=",
			fog_material.get_shader_parameter("boat_position"))
	else:
		push_error("[FogController] Water FogVolume or ShaderMaterial is missing")

func _process(_delta: float) -> void:
	if not fog_material:
		return
		
	# 实时把船的 3D 坐标传入 Shader，让水面低空雾随船移动推开
	# Transmit the ship's 3D coordinates to the shader in real time, so that the low-lying fog on the water's surface moves and parts as the ship passes through it.
	fog_material.set_shader_parameter("boat_position", global_position)
