@tool
extends StaticBody3D
## One reef (box placeholder). Move / rotate it with the gizmo; change its
## size and colour in the Inspector rather than scaling the node, so the
## collision shape stays unscaled.
## 一块礁石(长方体占位)。用变换工具移动 / 旋转;尺寸和颜色在检查器里改,
## 不要直接缩放节点,这样碰撞形状不会被拉伸。

## Placeholder size only; imported models use their own mesh for collision.
## 白模尺寸(米)，自定义模型的碰撞自动跟随模型，不受此尺寸影响。
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
var _box_collision: CollisionShape3D
var _model_collisions: Array[Node] = []
var _mesh_snapshot: Array = []


func _ready() -> void:
	# Refresh after editor drag/drop, deletion, and undo/redo.
	if not child_order_changed.is_connected(_queue_visual_refresh):
		child_order_changed.connect(_queue_visual_refresh)
	_rebuild()


func _process(_delta: float) -> void:
	# Includes transforms of nested meshes in imported GLB scenes.
	_sync_model_collision()


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
	_model_collisions.clear()
	_mesh_snapshot.clear()

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

	var shape := BoxShape3D.new()
	shape.size = size
	var col := CollisionShape3D.new()
	col.name = "ReefCollision"
	col.shape = shape
	col.position = offset
	_add(col)
	_box_collision = col
	_refresh_placeholder()


func _queue_visual_refresh() -> void:
	_refresh_placeholder.call_deferred()


func _refresh_placeholder() -> void:
	if not is_instance_valid(_placeholder):
		return
	# Only generated children belong to the placeholder system. Keep manually
	# added model scenes intact, including when size or colour is changed.
	for child in get_children():
		if child is Node3D and not child.is_queued_for_deletion() and not _generated.has(child):
			_placeholder.visible = false
			if Engine.is_editor_hint() and has_meta("_edit_group_"):
				# Imported models must remain independently selectable.
				remove_meta("_edit_group_")
			_sync_model_collision()
			return
	_placeholder.visible = true
	if Engine.is_editor_hint():
		# Only group bare placeholders, so deleting a box also removes its body.
		set_meta("_edit_group_", true)
	_sync_model_collision()


func _collect_model_meshes(node: Node, relative: Transform3D, records: Array) -> void:
	if node.is_queued_for_deletion() or _generated.has(node):
		return
	if node is Node3D:
		relative = relative * node.transform
	if node is MeshInstance3D and node.mesh != null:
		records.append([node.get_instance_id(), node.mesh, relative])
	for child in node.get_children():
		_collect_model_meshes(child, relative, records)


func _sync_model_collision() -> void:
	if not is_instance_valid(_placeholder) or not is_instance_valid(_box_collision):
		return
	var records: Array = []
	var has_model := false
	for child in get_children():
		if child is Node3D and not child.is_queued_for_deletion() and not _generated.has(child):
			has_model = true
			_collect_model_meshes(child, Transform3D.IDENTITY, records)
	if _box_collision.disabled != has_model:
		_box_collision.set_deferred("disabled", has_model)
	if records == _mesh_snapshot:
		return
	_mesh_snapshot = records
	for collision in _model_collisions:
		_generated.erase(collision)
		remove_child(collision)
		collision.queue_free()
	_model_collisions.clear()
	for record in records:
		var model_mesh: Mesh = record[1]
		var relative: Transform3D = record[2]
		var faces := model_mesh.get_faces()
		if faces.is_empty():
			continue
		# Bake all model transforms into vertices: collision nodes stay unscaled.
		for i in faces.size():
			faces[i] = relative * faces[i]
		var shape := ConcavePolygonShape3D.new()
		shape.backface_collision = true
		shape.set_faces(faces)
		var collision := CollisionShape3D.new()
		collision.name = "ModelCollision"
		collision.shape = shape
		_add(collision)
		_model_collisions.append(collision)


func _add(n: Node) -> void:
	n.set_meta(GENERATED_META, true)
	add_child(n)
	_generated.append(n)
	if Engine.is_editor_hint():
		var scene_root := get_tree().edited_scene_root
		if scene_root != null and scene_root.is_ancestor_of(n):
			# An owner makes the generated geometry selectable in the 3D editor.
			n.owner = scene_root
