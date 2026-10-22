extends "res://Scripts/memory_preview.gd"

@export var text_label: Label
@export_range(0.1, 10.0, 0.1) var text_fade_duration: float = 2.0
@export var ambient_audio: AudioStream
@export_range(-40.0, 6.0) var ambient_volume_db: float = -12.0

var _audio: AudioStreamPlayer


func _ready() -> void:
	text_label.modulate.a = 0.0
	text_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	super._ready()
	# Only the background participates in the text memory's picture animation.
	picture_layers.assign([$Memorylayers/Background])
	$Memorylayers/HiddenClue.hide()
	$Memorylayers/Foreground.hide()
	_audio = AudioStreamPlayer.new()
	_audio.stream = ambient_audio
	_audio.volume_db = ambient_volume_db
	add_child(_audio)


func _after_picture_revealed() -> void:
	if ambient_audio:
		_audio.play()
	var tween := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(text_label, "modulate:a", 1.0, text_fade_duration)
	await tween.finished


func _add_dissolve_animation(tween: Tween) -> void:
	tween.tween_property(text_label, "modulate:a", 0.0, dissolve_duration)
	if _audio.playing:
		tween.tween_property(_audio, "volume_db", -60.0, dissolve_duration)
		tween.finished.connect(_audio.stop)
