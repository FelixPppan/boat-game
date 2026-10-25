extends CanvasLayer
## Shows wave / thumbs-up icons from get_wave_phase() on any memory_triggers rock.

@export var wave_hint: TextureRect
@export var thumb_hint: TextureRect
@export_range(0.05, 1.0, 0.01) var fade_duration: float = 0.22
## Peak opacity when shown (lower = softer / less solid black).
@export_range(0.1, 1.0, 0.01) var hint_opacity: float = 0.55

var _phase := 0
var _wave_tween: Tween
var _thumb_tween: Tween


func _ready() -> void:
	for hint in [wave_hint, thumb_hint]:
		if hint == null:
			continue
		hint.visible = true
		hint.modulate.a = 0.0
		hint.mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(_delta: float) -> void:
	var phase := 0
	for trigger in get_tree().get_nodes_in_group("memory_triggers"):
		var p: int = trigger.get_wave_phase()
		if p != 0:
			phase = p
			break
	if phase == _phase:
		return
	_phase = phase
	_fade_hint(wave_hint, phase == 1, true)
	_fade_hint(thumb_hint, phase == 2, false)


func _fade_hint(hint: TextureRect, show: bool, is_wave: bool) -> void:
	if hint == null:
		return
	var tween := _wave_tween if is_wave else _thumb_tween
	if tween:
		tween.kill()
	tween = create_tween()
	tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	if is_wave:
		_wave_tween = tween
	else:
		_thumb_tween = tween
	var target_a := hint_opacity if show else 0.0
	tween.tween_property(hint, "modulate:a", target_a, fade_duration)
