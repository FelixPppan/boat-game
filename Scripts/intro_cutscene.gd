extends Node
## Opening cutscene: aerial mist shot + subtitles, then dive to the play camera.
## Space skips the current subtitle only (during dive, finishes the intro).

@export_group("Nodes")
@export var boat: RigidBody3D
@export var boat_camera: Camera3D
@export var intro_camera: Camera3D
@export var mist_rect: ColorRect
@export var subtitle: Label
@export var intro_ui: CanvasLayer

@export_group("Camera Start")
## World-space offset from the boat origin for the opening aerial shot.
@export var camera_start_offset: Vector3 = Vector3(0.0, 35.0, 25.0)
## Euler degrees applied as the intro camera's global rotation (pitch/yaw/roll).
@export var camera_start_rotation_degrees: Vector3 = Vector3(-45.0, 0.0, 0.0)

@export_group("Timing")
@export_range(0.0, 5.0, 0.05) var subtitle_fade_in: float = 0.8
@export_range(0.0, 10.0, 0.05) var subtitle_hold_1: float = 2.4
@export_range(0.0, 5.0, 0.05) var subtitle_fade_out: float = 0.7
@export_range(0.0, 10.0, 0.05) var subtitle_hold_2: float = 2.4
@export_range(0.0, 10.0, 0.05) var subtitle_hold_3: float = 2.4
@export_range(0.1, 15.0, 0.05) var dive_duration: float = 3.5
## Deep ocean navy (matches / darker than opening sea). Alpha applied from mist_start_alpha.
@export var mist_color: Color = Color(0.06, 0.07, 0.14, 1.0)
@export_range(0.0, 1.0, 0.01) var mist_start_alpha: float = 0.72

@export_group("Subtitle Style")
## Same handwritten font as TextMemory labels: res://font/SueEllenFrancisco-Regular.ttf
@export var subtitle_font: Font
@export_range(12, 72, 1) var subtitle_font_size: int = 34
## Extra pixels between lines (Label theme line_spacing).
@export_range(0, 40, 1) var subtitle_line_spacing: int = 12
## Extra pixels between glyphs (FontVariation spacing_glyph).
@export_range(0, 20, 1) var subtitle_glyph_spacing: int = 3
@export_range(0, 20, 1) var subtitle_space_spacing: int = 2

@export_group("Copy")
@export_multiline var text_1: String = (
	"I do not remember who I am,\n"
	+ "nor how I came to be in this forgotten ocean.\n"
	+ "All around me, there is only endless mist."
)
@export_multiline var text_2: String = (
	"Yet, somewhere in the depths, a faint light flickers…\n"
	+ "Those are scattered fragments of memory."
)
@export_multiline var text_3: String = (
	"If I gather them, piece by piece…\n"
	+ "Perhaps I will remember everything."
)

var _playing: bool = false
var _in_dive: bool = false
## Index of the subtitle currently playing (0..2). -1 before the first beat.
var _subtitle_index: int = -1
var _boat_process_mode: Node.ProcessMode = Node.PROCESS_MODE_INHERIT
var _tween: Tween


func _ready() -> void:
	_prepare_ui()
	start_intro()


func _unhandled_input(event: InputEvent) -> void:
	if not _playing:
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_SPACE:
		_on_space_pressed()
		get_viewport().set_input_as_handled()


func start_intro() -> void:
	if boat == null or boat_camera == null or intro_camera == null:
		push_warning("IntroCutscene: missing node references.")
		return
	if _playing:
		return

	_playing = true
	_in_dive = false
	_subtitle_index = -1
	_boat_process_mode = boat.process_mode
	boat.process_mode = Node.PROCESS_MODE_DISABLED

	_match_intro_camera_lens()
	_apply_intro_camera_start()
	intro_camera.make_current()

	if intro_ui:
		intro_ui.visible = true
	if mist_rect:
		var c := mist_color
		c.a = mist_start_alpha
		mist_rect.color = c
	if subtitle:
		subtitle.text = ""
		subtitle.modulate.a = 0.0

	_play_next_subtitle()


func _on_space_pressed() -> void:
	if _in_dive:
		_on_intro_finished()
		return
	# Skip only the current subtitle beat, then continue the sequence.
	_play_next_subtitle()


func _play_next_subtitle() -> void:
	if not _playing or _in_dive:
		return
	if _tween:
		_tween.kill()
		_tween = null

	_subtitle_index += 1
	if _subtitle_index >= 3:
		_begin_dive()
		return

	var texts: Array[String] = [text_1, text_2, text_3]
	var holds: Array[float] = [subtitle_hold_1, subtitle_hold_2, subtitle_hold_3]
	if subtitle:
		subtitle.text = texts[_subtitle_index]
		subtitle.modulate.a = 0.0

	_tween = create_tween()
	_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_tween.tween_property(subtitle, "modulate:a", 1.0, subtitle_fade_in)
	_tween.tween_interval(holds[_subtitle_index])
	_tween.tween_property(subtitle, "modulate:a", 0.0, subtitle_fade_out)
	_tween.tween_callback(_play_next_subtitle)


func _begin_dive() -> void:
	if not _playing:
		return
	_in_dive = true
	if _tween:
		_tween.kill()
	if subtitle:
		subtitle.modulate.a = 0.0
	_match_intro_camera_lens()
	var end_xform := boat_camera.global_transform
	_tween = create_tween()
	_tween.set_parallel(true)
	_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_tween.tween_property(intro_camera, "global_transform", end_xform, dive_duration)
	_tween.tween_property(intro_camera, "fov", boat_camera.fov, dive_duration)
	if mist_rect:
		_tween.tween_property(mist_rect, "color:a", 0.0, dive_duration)
	_tween.set_parallel(false)
	_tween.tween_callback(_on_intro_finished)


func _on_intro_finished() -> void:
	if not _playing:
		return
	_playing = false
	_in_dive = false
	if _tween:
		_tween.kill()
		_tween = null

	if subtitle:
		subtitle.modulate.a = 0.0
	if mist_rect:
		var c := mist_rect.color
		c.a = 0.0
		mist_rect.color = c
	if intro_ui:
		intro_ui.visible = false

	# Snap before switch so any tween/skip error does not pop.
	_match_intro_camera_lens()
	intro_camera.global_transform = boat_camera.global_transform
	boat_camera.make_current()
	boat.process_mode = _boat_process_mode


func _match_intro_camera_lens() -> void:
	intro_camera.fov = boat_camera.fov
	intro_camera.keep_aspect = boat_camera.keep_aspect
	intro_camera.near = boat_camera.near
	intro_camera.far = boat_camera.far


func _apply_intro_camera_start() -> void:
	intro_camera.global_position = boat.global_position + camera_start_offset
	intro_camera.global_rotation_degrees = camera_start_rotation_degrees


func _prepare_ui() -> void:
	if mist_rect:
		mist_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if subtitle:
		subtitle.mouse_filter = Control.MOUSE_FILTER_IGNORE
		subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		subtitle.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		subtitle.modulate.a = 0.0
		_apply_subtitle_style()
	if intro_ui:
		intro_ui.visible = false


func _apply_subtitle_style() -> void:
	if subtitle == null:
		return
	var base: Font = subtitle_font
	if base == null:
		base = load("res://font/SueEllenFrancisco-Regular.ttf") as Font
	if base != null:
		var variation := FontVariation.new()
		variation.base_font = base
		variation.spacing_glyph = subtitle_glyph_spacing
		variation.spacing_space = subtitle_space_spacing
		subtitle.add_theme_font_override("font", variation)
	subtitle.add_theme_font_size_override("font_size", subtitle_font_size)
	subtitle.add_theme_constant_override("line_spacing", subtitle_line_spacing)
