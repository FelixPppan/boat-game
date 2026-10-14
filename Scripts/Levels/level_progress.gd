extends CanvasLayer
## On-screen "collected / total" counter for every level goal in the scene
## (anything in the "level_target" group).
## 屏幕上的「已收集 / 总数」计数,统计场景里所有关卡目标(在 "level_target" 分组里的节点)。

@export var font_size: int = 40

var _label: Label
var _collected := 0
var _total := 0


func _ready() -> void:
	_label = Label.new()
	_label.add_theme_font_size_override("font_size", font_size)
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 8)
	_label.position = Vector2(24, 16)
	add_child(_label)
	# Targets join their group in their own _ready, which may run after ours.
	# 目标在自己的 _ready 里进分组,可能比这里晚。
	_connect_targets.call_deferred()


func _connect_targets() -> void:
	var targets := get_tree().get_nodes_in_group("level_target")
	_total = targets.size()
	for t in targets:
		t.collected.connect(_on_collected)
	_refresh()


func _on_collected() -> void:
	_collected += 1
	_refresh()


func _refresh() -> void:
	_label.text = "%d/%d" % [_collected, _total]
