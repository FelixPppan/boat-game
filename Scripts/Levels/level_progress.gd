extends CanvasLayer
## On-screen "collected / total" counter for every level goal in the scene
## (anything in the "level_target" group). While a level is being played the sun
## slowly turns towards that level's limit and waits there.
## 屏幕上的「已收集 / 总数」计数,统计场景里所有关卡目标(在 "level_target" 分组里的节点)。
## 每一关进行中,太阳慢慢转向这一关的上限角度,到了就停住等待。

@export var font_size: int = 40
## Debug shortcut: completes the next unfinished level.
## 调试快捷键:完成下一个还没完成的关卡。
@export var debug_complete_key: Key = KEY_C

@export_group("Sun")
@export var sun: DirectionalLight3D
## Sun rotation (degrees): game start, the limit of each level, then all levels done.
## 太阳角度(度):开局、每一关的上限,最后一项是全部完成。
@export var sun_stages: Array[Vector3] = [
	Vector3(38.0, 95.0, 54.0),
	Vector3(18.0, 96.0, 52.0),
	Vector3(4.0, 97.0, 50.0),
	Vector3(-8.0, 98.0, 48.0),
	Vector3(-70.0, 101.6, 40.0),
]
## Seconds the sun takes to reach the next stage. Larger is slower.
## 太阳转到下一个角度所用的秒数,越大越慢。
@export_range(0.1, 120.0, 0.5) var sun_turn_duration: float = 30.0

@export_group("Moon")
@export var moon: DirectionalLight3D
## Moonlight energy at game start.
## 开局时的月光强度。
@export_range(0.0, 2.0, 0.01) var moon_energy: float = 0.4
## How many degrees rotation.x has grown when the sun reaches the horizon.
## 太阳到地平线时,月亮 x 已经增加了多少度。
@export_range(0.0, 90.0, 0.5) var moon_dawn_drop_x: float = 6.0
## Fraction of the moonlight left when the sun reaches the horizon.
## 太阳到地平线时,月光还剩几成。
@export_range(0.0, 1.0, 0.01) var moon_dawn_energy: float = 0.6
## Total degrees rotation.x grows; the moon must end about 16 below the horizon to be hidden by the sky.
## 月亮 x 一共增加多少度;月亮要落到地平线下约 16 度,天空才会完全遮住它。
@export_range(0.0, 120.0, 0.5) var moon_total_drop_x: float = 35.0
## Sun elevation (degrees) at which the moonlight reaches 0 and the moon hides.
## 太阳升到这个仰角(度)时,月光为 0,月亮隐藏。
@export_range(0.1, 45.0, 0.1) var moon_gone_at_sun_elevation: float = 7.5

var _label: Label
var _collected := 0
var _total := 0
var _targets: Array[Node] = []
var _sun_tween: Tween
var _moon_rise_rotation: Vector3
var _sun_start_elevation: float


func _ready() -> void:
	_label = Label.new()
	_label.add_theme_font_size_override("font_size", font_size)
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 8)
	_label.position = Vector2(24, 16)
	add_child(_label)
	if sun and not sun_stages.is_empty():
		sun.rotation_degrees = sun_stages[0]
	if sun:
		_sun_start_elevation = _elevation(sun)
	if moon:
		_moon_rise_rotation = moon.rotation_degrees
	# Targets join their group in their own _ready, which may run after ours.
	# 目标在自己的 _ready 里进分组,可能比这里晚。
	_connect_targets.call_deferred()


func _connect_targets() -> void:
	_targets = get_tree().get_nodes_in_group("level_target")
	_total = _targets.size()
	for t in _targets:
		t.collected.connect(_on_collected)
	_refresh()
	_turn_sun()


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo or key.keycode != debug_complete_key:
		return
	for t in _targets:
		if not t._done:
			t.complete()
			break
	get_viewport().set_input_as_handled()


func _on_collected() -> void:
	_collected += 1
	_refresh()
	_turn_sun()


func _turn_sun() -> void:
	if sun == null or sun_stages.is_empty():
		return
	var target: Vector3 = sun_stages[mini(_collected + 1, sun_stages.size() - 1)]
	if _sun_tween:
		_sun_tween.kill()
	_sun_tween = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_sun_tween.tween_property(sun, "rotation_degrees", target, sun_turn_duration)


## Until the sun reaches the horizon the moon sinks a little and dims; while the
## sun rises above it the moon sets fully, the light reaches 0 and the moon hides.
## 太阳到地平线之前,月亮稍微下沉并变暗;太阳升过地平线后,月亮完全落下,月光降到 0 后隐藏。
func _process(_delta: float) -> void:
	if sun == null or moon == null:
		return
	var sun_elev := _elevation(sun)
	var drop: float
	var energy: float
	if sun_elev <= 0.0:
		var t := clampf(inverse_lerp(_sun_start_elevation, 0.0, sun_elev), 0.0, 1.0)
		drop = lerpf(0.0, moon_dawn_drop_x, t)
		energy = lerpf(1.0, moon_dawn_energy, t)
	else:
		var t := clampf(sun_elev / moon_gone_at_sun_elevation, 0.0, 1.0)
		drop = lerpf(moon_dawn_drop_x, moon_total_drop_x, t)
		energy = lerpf(moon_dawn_energy, 0.0, t)
	moon.rotation_degrees = _moon_rise_rotation + Vector3(drop, 0.0, 0.0)
	moon.light_energy = moon_energy * energy
	moon.visible = sun_elev < moon_gone_at_sun_elevation


static func _elevation(light: Node3D) -> float:
	return rad_to_deg(asin(clampf(light.global_basis.z.y, -1.0, 1.0)))


func _refresh() -> void:
	_label.text = "%d/%d" % [_collected, _total]
