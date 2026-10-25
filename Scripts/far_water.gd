extends Node3D
## Keeps the outer sea's waves in step with the main WaterPlane.
## Colours live in the outer sea material itself, so it looks right in the editor too.
## 让外圈海面的浪和主海面同步。颜色直接写在外圈材质里,编辑器里也能正确显示。

@export var water: MeshInstance3D
@export var far_material: ShaderMaterial

"""
func _process(_delta: float) -> void:
	far_material.set_shader_parameter("time", water.get("time"))
"""
