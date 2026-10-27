extends Node
## Ending: aerial return → soft memory carousel → 5 subtitle beats → fade to white.
## Space skips the current beat (same idea as IntroCutscene).
## Soft edges: memory_soft_mask.png as an enlarged clip mask (center kept, edges fade).

@export_group("Nodes")
@export var boat: RigidBody3D
@export var boat_camera: Camera3D
@export var cutscene_camera: Camera3D
@export var ending_ui: CanvasLayer
@export var overlay: ColorRect
## Frame sized to each memory texture (aspect-fit).
@export var photo_root: Control
## Soft clip mask (not drawn; clips Photo). Scaled up so more of the soft center shows.
@export var photo_mask: TextureRect
## Memory image inside the mask.
@export var photo_image: TextureRect
@export var photo_background: TextureRect
@export var subtitle: Label
@export var end_label: Label
## MemoryRock4 Area3D — plays ending on interaction_finished.
@export var trigger: Area3D

@export_group("Camera Return")
@export var camera_start_offset: Vector3 = Vector3(0.0, 35.0, 25.0)
@export var camera_start_rotation_degrees: Vector3 = Vector3(-45.0, 0.0, 0.0)
@export_range(0.5, 15.0, 0.1) var camera_return_duration: float = 3.5
@export var mist_color: Color = Color(0.90, 0.93, 0.98, 1.0)
@export_range(0.0, 1.0, 0.01) var overlay_alpha: float = 0.68

@export_group("Carousel")
@export var memory_textures: Array[Texture2D] = []
@export_range(0.1, 3.0, 0.05) var photo_fade_in: float = 0.8
@export_range(0.1, 10.0, 0.05) var photo_hold: float = 1.2
@export_range(0.1, 3.0, 0.05) var photo_fade_out: float = 0.5
@export_range(0.5, 1.0, 0.01) var photo_peak_opacity: float = 1.0
@export var photo_max_width: float = 720.0
@export var photo_max_height: float = 540.0
## >1 zooms into the soft mask center → larger clear middle. Try 1.1–1.5.
@export_range(1.0, 3.0, 0.05) var mask_expand: float = 1.25

@export_group("Finale")
@export_range(0.1, 5.0, 0.05) var subtitle_fade_in: float = 0.8
@export_range(0.1, 5.0, 0.05) var subtitle_fade_out: float = 0.7
@export_range(0.5, 15.0, 0.1) var subtitle_hold_1: float = 2.5
@export_range(0.5, 15.0, 0.1) var subtitle_hold_2: float = 4.0
@export_range(0.5, 15.0, 0.1) var subtitle_hold_3: float = 4.0
@export_range(0.5, 15.0, 0.1) var subtitle_hold_4: float = 4.0
@export_range(0.5, 15.0, 0.1) var subtitle_hold_5: float = 3.5
@export_range(0.5, 8.0, 0.1) var white_fade_duration: float = 2.5

@export_group("Copy")
@export_multiline var text_1: String = "I remember now… I was a little dog."
@export_multiline var text_2: String = (
	"I knew the jumpy cat next door,\n"
	+ "chased my favorite toy across the endless grass,\n"
	+ "and even got to feel like I was flying, high up in your arms!"
)
@export_multiline var text_3: String = (
	"Sometimes, I couldn’t understand what you were saying.\n"
	+ "And sometimes, I had to wait by the door all alone,\n"
	+ "hoping you would come home soon…"
)
@export_multiline var text_4: String = (
	"But looking at us in that photo, I know now\n"
	+ "that my days were filled with wonderful adventures\n"
	+ "and surrounded by so much love."
)
@export_multiline var text_5: String = (
	"With all these sparkling memories in my heart,\n"
	+ "it’s time to set off on my next adventure!"
)

@export_group("Subtitle Style")
@export var subtitle_font: Font
@export_range(12, 72, 1) var subtitle_font_size: int = 48
@export_range(0, 40, 1) var subtitle_line_spacing: int = 6
@export_range(0, 20, 1) var subtitle_glyph_spacing: int = 3
@export_range(0, 20, 1) var subtitle_space_spacing: int = 2

@export_group("Audio")
## Happy ending track (e.g. Sea_of_Memories_Happy_Music.mp3). Leave empty to skip.
@export var ending_music: AudioStream
@export var ending_music_player: AudioStreamPlayer
@export_range(-40.0, 6.0, 0.5) var ending_music_volume_db: float = -6.0
## How many times to play the ending track (no infinite loop).
@export_range(1, 10, 1) var ending_music_play_count: int = 2
## Crossfade length between FMOD BGM and ending music.
@export_range(0.5, 10.0, 0.1) var music_crossfade_duration: float = 3.0

enum Phase { IDLE, RISE, CAROUSEL, SUBTITLES, WHITE, DONE }

var _playing: bool = false
var _phase: Phase = Phase.IDLE
var _carousel_index: int = -1
var _subtitle_index: int = -1
var _boat_process_mode: Node.ProcessMode = Node.PROCESS_MODE_INHERIT
var _tween: Tween
var _music_fade_tween: Tween
var _frame_size: Vector2 = Vector2(720, 540)
var _ending_music_plays_left: int = 0


func _ready() -> void:
	_prepare_ui()
	if trigger and not trigger.interaction_finished.is_connected(play_ending):
		trigger.interaction_finished.connect(play_ending)


func _unhandled_input(event: InputEvent) -> void:
	if not _playing or _phase == Phase.DONE or _phase == Phase.IDLE:
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_SPACE:
		_on_space_pressed()
		get_viewport().set_input_as_handled()


func play_ending() -> void:
	if _playing:
		return
	if boat == null or cutscene_camera == null:
		push_warning("EndingManager: missing boat or cutscene_camera.")
		return
	_playing = true
	_phase = Phase.RISE
	_carousel_index = -1
	_subtitle_index = -1

	_boat_process_mode = boat.process_mode
	boat.process_mode = Node.PROCESS_MODE_DISABLED

	if boat_camera:
		cutscene_camera.fov = boat_camera.fov
		cutscene_camera.keep_aspect = boat_camera.keep_aspect
		cutscene_camera.global_transform = boat_camera.global_transform
	cutscene_camera.make_current()

	if ending_ui:
		ending_ui.visible = true
	_apply_mist_overlay(0.0)
	_clear_photo()
	if photo_background:
		photo_background.visible = false
		photo_background.modulate.a = 0.0
		photo_background.texture = null
	_set_label_alpha(subtitle, 0.0)
	_set_label_alpha(end_label, 0.0)
	if end_label:
		end_label.visible = false
	if subtitle:
		subtitle.text = ""

	_start_ending_music_crossfade()
	_start_rise()


func _on_space_pressed() -> void:
	match _phase:
		Phase.RISE:
			_kill_tween()
			_snap_rise_done()
			_start_carousel()
		Phase.CAROUSEL:
			_kill_tween()
			_set_photo_alpha(0.0)
			_play_next_photo()
		Phase.SUBTITLES:
			_kill_tween()
			if subtitle:
				subtitle.modulate.a = 0.0
			_play_next_subtitle()
		Phase.WHITE:
			_kill_tween()
			_snap_white_done()
		_:
			pass


func _start_rise() -> void:
	_phase = Phase.RISE
	_kill_tween()
	var aerial := _aerial_transform()
	_tween = create_tween()
	_tween.set_parallel(true)
	_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_tween.tween_property(cutscene_camera, "global_transform", aerial, camera_return_duration)
	if overlay:
		_apply_mist_overlay(0.0)
		_tween.tween_property(overlay, "color:a", overlay_alpha, camera_return_duration)
	_tween.set_parallel(false)
	_tween.tween_callback(_start_carousel)


func _snap_rise_done() -> void:
	cutscene_camera.global_transform = _aerial_transform()
	_apply_mist_overlay(overlay_alpha)


func _start_carousel() -> void:
	_phase = Phase.CAROUSEL
	_carousel_index = -1
	_apply_mist_overlay(overlay_alpha)
	_play_next_photo()


func _play_next_photo() -> void:
	if not _playing or _phase != Phase.CAROUSEL:
		return
	_kill_tween()
	_carousel_index += 1
	while _carousel_index < memory_textures.size() and memory_textures[_carousel_index] == null:
		_carousel_index += 1
	if _carousel_index >= memory_textures.size():
		_begin_subtitles()
		return

	_set_photo_texture(memory_textures[_carousel_index])
	_set_photo_alpha(0.0)
	_tween = create_tween()
	_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_tween.tween_method(_set_photo_alpha, 0.0, photo_peak_opacity, photo_fade_in)
	_tween.tween_interval(photo_hold)
	_tween.tween_method(_set_photo_alpha, photo_peak_opacity, 0.0, photo_fade_out)
	_tween.tween_callback(_play_next_photo)


func _begin_subtitles() -> void:
	_phase = Phase.SUBTITLES
	_subtitle_index = -1
	_kill_tween()
	_clear_photo()
	if photo_background:
		photo_background.visible = false
		photo_background.modulate.a = 0.0
	if subtitle:
		subtitle.modulate.a = 0.0
	_apply_mist_overlay(overlay_alpha)
	_play_next_subtitle()


func _play_next_subtitle() -> void:
	if not _playing or _phase != Phase.SUBTITLES:
		return
	_kill_tween()
	_subtitle_index += 1
	if _subtitle_index >= 5:
		_start_white()
		return

	var texts: Array[String] = [text_1, text_2, text_3, text_4, text_5]
	var holds: Array[float] = [
		subtitle_hold_1, subtitle_hold_2, subtitle_hold_3, subtitle_hold_4, subtitle_hold_5
	]
	if subtitle:
		subtitle.text = texts[_subtitle_index]
		subtitle.modulate.a = 0.0

	_tween = create_tween()
	_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_tween.tween_property(subtitle, "modulate:a", 1.0, subtitle_fade_in)
	_tween.tween_interval(holds[_subtitle_index])
	_tween.tween_property(subtitle, "modulate:a", 0.0, subtitle_fade_out)
	_tween.tween_callback(_play_next_subtitle)


func _start_white() -> void:
	_phase = Phase.WHITE
	_kill_tween()
	if end_label:
		end_label.visible = true
		end_label.text = "THE END"
		end_label.modulate.a = 0.0

	_tween = create_tween()
	_tween.set_parallel(true)
	_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	if overlay:
		_tween.tween_property(overlay, "color", Color(1, 1, 1, 1), white_fade_duration)
	if end_label:
		_tween.tween_property(end_label, "modulate:a", 1.0, white_fade_duration)
	if subtitle:
		_tween.tween_property(subtitle, "modulate:a", 0.0, white_fade_duration * 0.5)
	_tween.tween_method(_set_photo_alpha, _get_photo_alpha(), 0.0, white_fade_duration * 0.5)
	_tween.set_parallel(false)
	_tween.tween_callback(_finish_ending)


func _snap_white_done() -> void:
	if overlay:
		overlay.color = Color(1, 1, 1, 1)
	if end_label:
		end_label.visible = true
		end_label.text = "THE END"
		end_label.modulate.a = 1.0
	if subtitle:
		subtitle.modulate.a = 0.0
	_set_photo_alpha(0.0)
	_finish_ending()


func _finish_ending() -> void:
	_phase = Phase.DONE
	_kill_tween()
	_playing = false


func _kill_tween() -> void:
	if _tween:
		_tween.kill()
		_tween = null


func _aerial_transform() -> Transform3D:
	var origin := boat.global_position + camera_start_offset
	var basis := Basis.from_euler(Vector3(
		deg_to_rad(camera_start_rotation_degrees.x),
		deg_to_rad(camera_start_rotation_degrees.y),
		deg_to_rad(camera_start_rotation_degrees.z)
	))
	return Transform3D(basis, origin)


func _prepare_ui() -> void:
	if ending_ui:
		ending_ui.visible = false
	for c in [overlay, photo_root, photo_mask, photo_image, photo_background, subtitle, end_label]:
		if c is CanvasItem:
			(c as CanvasItem).mouse_filter = Control.MOUSE_FILTER_IGNORE
	_apply_mist_overlay(0.0)
	_setup_photo_mask()
	_clear_photo()
	if photo_background:
		photo_background.visible = false
		photo_background.modulate.a = 0.0
	_set_label_alpha(subtitle, 0.0)
	_set_label_alpha(end_label, 0.0)
	if end_label:
		end_label.visible = false
	_apply_subtitle_style()
	_prepare_ending_music()


func _prepare_ending_music() -> void:
	if ending_music_player == null:
		ending_music_player = AudioStreamPlayer.new()
		ending_music_player.name = "EndingMusic"
		add_child(ending_music_player)
	if ending_music != null:
		ending_music_player.stream = ending_music
	if ending_music_player.stream is AudioStreamMP3:
		(ending_music_player.stream as AudioStreamMP3).loop = false
	if not ending_music_player.finished.is_connected(_on_ending_music_finished):
		ending_music_player.finished.connect(_on_ending_music_finished)
	ending_music_player.volume_db = -40.0
	ending_music_player.stop()
	_ending_music_plays_left = 0


func _start_ending_music_crossfade() -> void:
	_prepare_ending_music()
	if ending_music_player == null or ending_music_player.stream == null:
		return

	if _music_fade_tween:
		_music_fade_tween.kill()
		_music_fade_tween = null

	var bgm := _get_fmod_bgm_emitter()
	var fade := maxf(music_crossfade_duration, 0.05)
	_music_fade_tween = create_tween()
	_music_fade_tween.set_parallel(true)
	_music_fade_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

	if bgm != null:
		var from_vol := 0.2
		if "volume" in bgm:
			from_vol = float(bgm.volume)
		_music_fade_tween.tween_property(bgm, "volume", 0.0, fade).from(from_vol)

	_ending_music_plays_left = maxi(ending_music_play_count, 1)
	ending_music_player.volume_db = -40.0
	if not ending_music_player.playing:
		ending_music_player.play()
		_ending_music_plays_left -= 1
	_music_fade_tween.tween_property(
		ending_music_player, "volume_db", ending_music_volume_db, fade
	).from(-40.0)

	_music_fade_tween.set_parallel(false)
	_music_fade_tween.tween_callback(_stop_fmod_bgm.bind(bgm))


func _on_ending_music_finished() -> void:
	if _ending_music_plays_left <= 0 or ending_music_player == null:
		return
	_ending_music_plays_left -= 1
	ending_music_player.play()


func _get_fmod_bgm_emitter() -> Node:
	var mgr := get_node_or_null("/root/MusicManager")
	if mgr == null:
		return null
	return mgr.get_node_or_null("FmodEventEmitter2D")


func _stop_fmod_bgm(bgm: Node) -> void:
	if bgm == null:
		return
	if bgm.has_method("stop"):
		bgm.call("stop")
	elif "volume" in bgm:
		bgm.volume = 0.0


func _setup_photo_mask() -> void:
	if photo_root == null:
		return
	# Clip overflow from the enlarged mask so only the frame area shows.
	photo_root.clip_contents = true
	if photo_mask:
		# Mask is NOT drawn; its alpha keeps the photo in the soft center and fades edges.
		photo_mask.clip_children = Control.CLIP_CHILDREN_ONLY
		photo_mask.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		photo_mask.stretch_mode = TextureRect.STRETCH_SCALE
		photo_mask.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if photo_image:
		photo_image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		photo_image.stretch_mode = TextureRect.STRETCH_SCALE
		photo_image.mouse_filter = Control.MOUSE_FILTER_IGNORE


func _set_photo_texture(tex: Texture2D) -> void:
	if photo_image:
		photo_image.texture = tex
	_fit_photo_frame_to_texture(tex)
	_layout_mask_and_photo()
	if photo_root:
		photo_root.visible = true


func _fit_photo_frame_to_texture(tex: Texture2D) -> void:
	if photo_root == null or tex == null:
		return
	var tw := float(tex.get_width())
	var th := float(tex.get_height())
	if tw <= 0.0 or th <= 0.0:
		return
	var aspect := tw / th
	var w := photo_max_width
	var h := w / aspect
	if h > photo_max_height:
		h = photo_max_height
		w = h * aspect
	_frame_size = Vector2(w, h)
	photo_root.offset_left = -w * 0.5
	photo_root.offset_right = w * 0.5
	photo_root.offset_top = -h * 0.5
	photo_root.offset_bottom = h * 0.5


func _layout_mask_and_photo() -> void:
	if photo_mask == null or photo_image == null:
		return
	# Enlarge soft mask so its opaque center covers more of the frame.
	# Parent clip_contents hides overflow.
	var mask_size := _frame_size * mask_expand
	var mask_pos := (_frame_size - mask_size) * 0.5
	photo_mask.position = mask_pos
	photo_mask.size = mask_size
	# Photo matches the visible frame, centered inside the enlarged mask.
	var photo_pos := (mask_size - _frame_size) * 0.5
	photo_image.position = photo_pos
	photo_image.size = _frame_size


func _clear_photo() -> void:
	_set_photo_alpha(0.0)
	if photo_image:
		photo_image.texture = null
	if photo_root:
		photo_root.visible = false


func _set_photo_alpha(a: float) -> void:
	if photo_root:
		photo_root.modulate.a = a


func _get_photo_alpha() -> float:
	if photo_root:
		return photo_root.modulate.a
	return 0.0


func _apply_mist_overlay(alpha: float) -> void:
	if overlay == null:
		return
	var c := mist_color
	c.a = alpha
	overlay.color = c


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
	if end_label != null and base != null:
		var end_var := FontVariation.new()
		end_var.base_font = base
		end_var.spacing_glyph = subtitle_glyph_spacing
		end_label.add_theme_font_override("font", end_var)


func _set_label_alpha(node: CanvasItem, a: float) -> void:
	if node:
		node.modulate.a = a
