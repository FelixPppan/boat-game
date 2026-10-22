@tool
extends Node3D
## Level 3: a water jet (cylinder placeholder). When the player's boat touches
## the marked zone on the water, a column shoots up and lifts the boat to the
## top, then holds it there for as long as the boat stays within the jet's
## horizontal range. Once the boat sails out of range it falls freely, and the
## column dies down hold_time seconds later.
## 第三关:水柱(先用圆柱体占位)。玩家的船碰到水面上标出的区域就会喷起水柱,
## 把船顶到柱顶,并且只要船还在水柱的水平范围内就一直托住不掉。
## 船驶离范围后自由落下,水柱在 hold_time 秒后才落下。

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
## Extra distance beyond the column radius at which the boat still counts as
## on the jet (m), roughly half the hull's width.
## 超出水柱半径多远船仍算在水柱上(米),大约是船宽的一半。
@export_range(0.0, 5.0, 0.05) var hold_margin: float = 0.5
## A boat this far above the column top is out of reach: the jet neither
## triggers nor pushes it, so a boat falling from above is caught only once
## the column gets to it.
## 船高出柱顶超过这个距离就够不着:水柱既不会被触发也顶不到它,
## 所以从上方落下的船要等水柱够到它才会被接住。
@export_range(0.1, 10.0, 0.1) var reach_margin: float = 1.5
## Extra slowing applied to the boat while it is on the jet (1/s), to make
## stopping on it easier. 0 disables it; the boat can still paddle out.
## 船在水柱范围内时额外的减速(1/秒),方便停船。设为 0 关闭;船仍能划出去。
@export_range(0.0, 10.0, 0.05) var brake_strength: float = 1.0
@export var jet_color: Color = Color(0.6, 0.85, 1.0, 0.55):
	set(value):
		jet_color = value
		_queue_rebuild()
@export var zone_color: Color = Color(0.85, 0.95, 1.0, 0.45):
	set(value):
		zone_color = value
		_queue_rebuild()

const ZONE_Y := 0.15

var _container: Node3D
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
	if _boat == null:
		_boat = get_tree().get_first_node_in_group("player_boat") as Node3D

	var on_jet := _boat_on_jet()
	if on_jet:
		_spray_timer = hold_time
	else:
		_spray_timer = maxf(0.0, _spray_timer - delta)

	if _spray_timer > 0.0:
		_current_height = move_toward(_current_height, jet_height, rise_speed * delta)
	else:
		_current_height = move_toward(_current_height, 0.0, fall_speed * delta)
	_set_column(_current_height)

	if on_jet and _boat.has_method("add_lift"):
		_boat.add_lift(_current_height)
		_boat.add_brake(brake_strength)


func _boat_on_jet() -> bool:
	if _boat == null:
		return false
	var p := to_local(_boat.global_position)
	if Vector2(p.x, p.z).length() > radius + hold_margin:
		return false
	return p.y <= _current_height + reach_margin
