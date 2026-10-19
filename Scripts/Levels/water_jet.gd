@tool
extends Node3D
## Level 3: a water jet (cylinder placeholder). When the player's boat touches
## the marked zone on the water, a column shoots up and lifts the boat to the
## top. The jet keeps spraying while the boat is on it, then dies down
## hold_time seconds after the boat leaves.
## 第三关:水柱(先用圆柱体占位)。玩家的船碰到水面上标出的区域就会喷起水柱,
## 把船顶到柱顶。船在水柱上时持续喷射,离开后 hold_time 秒才落下。

## Spray height (m above the water).
## 喷射高度(水面以上,米)。
@export_range(0.5, 50.0, 0.1) var jet_height: float = 7.0:
	set(value):
		jet_height = value
		_queue_rebuild()
## Jet and trigger-zone radius (m).
## 水柱和触发区域的半径(米)。
@export_range(0.2, 10.0, 0.05) var radius: float = 1.2:
	set(value):
		radius = value
		_queue_rebuild()
## How fast the column rises / falls (m/s).
## 水柱升起 / 落下的速度(米/秒)。
@export_range(0.1, 50.0, 0.1) var rise_speed: float = 6.0
@export_range(0.1, 50.0, 0.1) var fall_speed: float = 4.0
## Seconds the jet keeps spraying after the boat leaves it.
## 船离开后水柱继续喷射的秒数。
@export_range(0.0, 30.0, 0.1) var hold_time: float = 1.5
@export var jet_color: Color = Color(0.6, 0.85, 1.0, 0.55):
	set(value):
		jet_color = value
		_queue_rebuild()
@export var zone_color: Color = Color(0.85, 0.95, 1.0, 0.45):
	set(value):
		zone_color = value
		_queue_rebuild()

## Margin above jet_height the trigger column extends, so a boat riding the
## top is still counted as on the jet.
## 触发柱比 jet_height 再高出的余量,船骑在柱顶时仍算在水柱上。
const AREA_HEADROOM := 3.0
const ZONE_Y := 0.15

var _container: Node3D
var _area: Area3D
var _column: MeshInstance3D
var _pending := false
var _boat: Node3D
var _current_height := 0.0
var _spray_timer := 0.0


func _ready() -> void:
	_rebuild()


func _queue_rebuild() -> void:
	if not is_inside_tree() or _pending:
		return
	_pending = true
	_rebuild.call_deferred()


func _rebuild() -> void:
	_pending = false
	_boat = null
	if _container != null:
		_container.queue_free()
	_container = Node3D.new()
	_container.name = "_Jet"
	add_child(_container)

	var zone_mat := _translucent(zone_color)
	var zone := CylinderMesh.new()
	zone.top_radius = radius
	zone.bottom_radius = radius
	zone.height = 0.05
	zone.material = zone_mat
	var zone_mesh := MeshInstance3D.new()
	zone_mesh.mesh = zone
	zone_mesh.position.y = ZONE_Y
	_container.add_child(zone_mesh)

	# Unit-height cylinder, scaled on Y to the current spray height.
	# 单位高度的圆柱,在 Y 上缩放到当前喷射高度。
	var col_mesh := CylinderMesh.new()
	col_mesh.top_radius = radius * 0.85
	col_mesh.bottom_radius = radius
	col_mesh.height = 1.0
	col_mesh.material = _translucent(jet_color)
	_column = MeshInstance3D.new()
	_column.mesh = col_mesh
	_container.add_child(_column)
	# Preview the full jet in the editor so its height can be tuned by eye.
	# 编辑器里预览完整水柱,方便目测调高度。
	_set_column(jet_height if Engine.is_editor_hint() else _current_height)

	_area = Area3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = radius
	shape.height = jet_height + AREA_HEADROOM + 1.0
	var col := CollisionShape3D.new()
	col.shape = shape
	col.position.y = shape.height * 0.5 - 1.0
	_area.add_child(col)
	_container.add_child(_area)
	if not Engine.is_editor_hint():
		_area.body_entered.connect(_on_body_entered)
		_area.body_exited.connect(_on_body_exited)


func _translucent(c: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = c
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = Color(c.r, c.g, c.b)
	mat.emission_energy_multiplier = 0.4
	return mat


func _set_column(h: float) -> void:
	_column.visible = h > 0.05
	_column.scale = Vector3(1.0, maxf(h, 0.01), 1.0)
	_column.position.y = h * 0.5


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if _boat != null:
		_spray_timer = hold_time
	else:
		_spray_timer = maxf(0.0, _spray_timer - delta)

	if _spray_timer > 0.0:
		_current_height = move_toward(_current_height, jet_height, rise_speed * delta)
	else:
		_current_height = move_toward(_current_height, 0.0, fall_speed * delta)
	_set_column(_current_height)

	if _boat != null and _boat.has_method("add_lift"):
		_boat.add_lift(_current_height)


func _on_body_entered(body: Node) -> void:
	if body.is_in_group("player_boat"):
		_boat = body


func _on_body_exited(body: Node) -> void:
	if body == _boat:
		_boat = null
