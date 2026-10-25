extends OmniLight3D
## Glow for a memory fragment: this light lights the surroundings and fog, and
## every mesh under glow_root gets an additive color overlay.
## 记忆碎片发光:这盏点光源照亮周围和雾,glow_root 下的模型叠一层发光颜色。

@export var glow_root: Node3D
## Overlay color; higher alpha = brighter. 发光颜色,透明度越高越亮。
@export var glow_color: Color = Color(1.0, 0.82, 0.2, 0.45)


func _ready() -> void:
	if glow_root == null:
		return
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = glow_color
	_apply(glow_root, mat)


func _apply(node: Node, mat: Material) -> void:
	if node is MeshInstance3D:
		node.material_overlay = mat
	for child in node.get_children():
		_apply(child, mat)
