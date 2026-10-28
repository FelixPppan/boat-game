extends CanvasLayer
## Bottom-left progress icons: cat / ball / balloon / question→home.
## Black silhouette textures are tinted gray or white via icon_tint.gdshader.
## Visible from intro end until ending starts.

const TINT_SHADER := preload("res://Shaders/icon_tint.gdshader")

@export_group("Wiring")
@export var intro: Node
@export var ending: Node
## MemoryRock4 Area3D — home turns white when this memory interaction starts.
@export var home_memory_trigger: Area3D
## Level1 / Level2 / Level3 Target nodes (MemoryRock1–3).
@export var level_targets: Array[NodePath] = []

@export_group("Icons")
@export var icon_cat: Texture2D
@export var icon_ball: Texture2D
@export var icon_balloon: Texture2D
@export var icon_question: Texture2D
@export var icon_home: Texture2D

@export_group("Layout")
@export_range(16.0, 160.0, 1.0) var icon_size: float = 56.0
@export_range(0.0, 48.0, 1.0) var icon_spacing: float = 10.0
@export_range(0.0, 120.0, 1.0) var margin_left: float = 28.0
@export_range(0.0, 120.0, 1.0) var margin_bottom: float = 28.0

@export_group("Colors")
@export var gray_color: Color = Color(0.55, 0.55, 0.55, 1.0)
@export var white_color: Color = Color(1.0, 1.0, 1.0, 1.0)

var _icons: Array[TextureRect] = []
var _done: Array[bool] = [false, false, false]
var _home_unlocked := false


func _ready() -> void:
	layer = 24
	visible = false
	_build_ui()
	_connect_signals.call_deferred()


func _build_ui() -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	var row := HBoxContainer.new()
	row.anchor_left = 0.0
	row.anchor_top = 1.0
	row.anchor_right = 0.0
	row.anchor_bottom = 1.0
	row.grow_horizontal = Control.GROW_DIRECTION_END
	row.grow_vertical = Control.GROW_DIRECTION_BEGIN
	row.offset_left = margin_left
	row.offset_top = -margin_bottom - icon_size
	row.offset_right = margin_left + icon_size * 4.0 + icon_spacing * 3.0
	row.offset_bottom = -margin_bottom
	row.add_theme_constant_override("separation", int(icon_spacing))
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(row)

	var textures: Array[Texture2D] = [icon_cat, icon_ball, icon_balloon, icon_question]
	for tex in textures:
		var icon := _make_icon(tex)
		row.add_child(icon)
		_icons.append(icon)


func _make_icon(tex: Texture2D) -> TextureRect:
	var rect := TextureRect.new()
	rect.texture = tex
	rect.custom_minimum_size = Vector2(icon_size, icon_size)
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = TINT_SHADER
	mat.set_shader_parameter("tint", gray_color)
	rect.material = mat
	return rect


func _connect_signals() -> void:
	if intro and intro.has_signal("intro_finished"):
		if not intro.intro_finished.is_connected(show):
			intro.intro_finished.connect(show)
	if ending and ending.has_signal("ending_started"):
		if not ending.ending_started.is_connected(hide):
			ending.ending_started.connect(hide)
	for i in range(mini(level_targets.size(), 3)):
		var target := get_node_or_null(level_targets[i])
		if target and target.has_signal("collected"):
			target.collected.connect(_on_level_collected.bind(i))
	if home_memory_trigger and home_memory_trigger.has_signal("interaction_started"):
		if not home_memory_trigger.interaction_started.is_connected(_on_home_memory_started):
			home_memory_trigger.interaction_started.connect(_on_home_memory_started)


func _on_level_collected(index: int) -> void:
	if index < 0 or index >= 3 or _done[index]:
		return
	_done[index] = true
	_set_tint(_icons[index], white_color)
	if _done[0] and _done[1] and _done[2] and not _home_unlocked:
		_home_unlocked = true
		if icon_home and _icons.size() > 3:
			_icons[3].texture = icon_home
		_set_tint(_icons[3], gray_color)


func _on_home_memory_started() -> void:
	if _icons.size() > 3:
		_set_tint(_icons[3], white_color)


func _set_tint(icon: TextureRect, color: Color) -> void:
	if icon == null:
		return
	var mat := icon.material as ShaderMaterial
	if mat:
		mat.set_shader_parameter("tint", color)
