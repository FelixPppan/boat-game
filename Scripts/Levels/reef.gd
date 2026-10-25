@tool
extends StaticBody3D
## One reef (box placeholder). Move / rotate it with the gizmo; change its
## size and colour in the Inspector rather than scaling the node, so the
## collision shape stays unscaled.
## 一块礁石(长方体占位)。用变换工具移动 / 旋转;尺寸和颜色在检查器里改,
## 不要直接缩放节点,这样碰撞形状不会被拉伸。

## Placeholder size only. Add collision shapes manually under this body.
## 白模尺寸（米）。碰撞请手动添加，不再自动生成。
@export var size: Vector3 = Vector3(1.2, 2.5, 2.5):
	set(value):
		size = value
		_rebuild()
@export var color: Color = Color(0.32, 0.3, 0.3):
	set(value):
		color = value
		_rebuild()

const SUNK_DEPTH := 1.0
const GENERATED_META := "_reef_generated"

var _generated: Array[Node] = []
var _placeholder: MeshInstance3D


func _ready() -> void:
	# Refresh after editor drag/drop, deletion, and undo/redo.
	if not child_order_changed.is_connected(_queue_visual_refresh):
		child_order_changed.connect(_queue_visual_refresh)
	_rebuild()


func _rebuild() -> void:
	if not is_inside_tree():
		return
	# Owned preview nodes can be saved by the editor. Remove those too when
	# reopening the scene, rather than accumulating duplicate meshes/shapes.
	for n in get_children():
		if _generated.has(n) or n.has_meta(GENERATED_META):
			remove_child(n)
			n.queue_free()
	_generated.clear()

	var offset := Vector3(0.0, size.y * 0.5 - SUNK_DEPTH, 0.0)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.9
	var box := BoxMesh.new()
	box.size = size
	box.material = mat
	var mesh := MeshInstance3D.new()
	mesh.name = "ReefPreview"
	mesh.mesh = box
	mesh.position = offset
	_add(mesh)
	_placeholder = mesh

	_refresh_placeholder()


func _queue_visual_refresh() -> void:
	_refresh_placeholder.call_deferred()


func _refresh_placeholder() -> void:
	if not is_instance_valid(_placeholder):
		return
	var has_model := false
	for child in get_children():
		if child is Node3D and not child.is_queued_for_deletion() and not _generated.has(child):
			if child is MeshInstance3D or not child.find_children("*", "MeshInstance3D").is_empty():
				has_model = true
				break
	_placeholder.visible = not has_model
	if Engine.is_editor_hint():
		if has_model:
			remove_meta("_edit_group_")
		else:
			set_meta("_edit_group_", true)


func _add(n: Node) -> void:
	n.set_meta(GENERATED_META, true)
	add_child(n)
	_generated.append(n)
	if Engine.is_editor_hint():
		var scene_root := get_tree().edited_scene_root
		if scene_root != null and scene_root.is_ancestor_of(n):
			# An owner makes the generated geometry selectable in the 3D editor.
			n.owner = scene_root
