extends MeshInstance3D

@export var slide_distance: float = 1.3
@export_range(0.0, 5.0, 0.1) var auto_move_delay: float = 0.5
@export_range(0.1, 5.0, 0.1) var slide_duration: float = 1.2
@export_range(0.0, 0.2, 0.005) var bounce_height: float = 0.02
@export_range(0.05, 1.0, 0.05) var bounce_duration: float = 0.2

@onready var memory_preview: Node = get_parent().get_parent()

var start_position: Vector3
var slide_tween: Tween


func _ready() -> void:
	start_position = position
	memory_preview.reveal_finished.connect(open_layer)
	memory_preview.exploration_ended.connect(stop_exploration)


func open_layer() -> void:
	var target := start_position + Vector3(0.0, -slide_distance, 0.0)
	slide_tween = create_tween()
	slide_tween.tween_interval(auto_move_delay)
	slide_tween.set_trans(Tween.TRANS_SINE)
	slide_tween.set_ease(Tween.EASE_IN_OUT)
	slide_tween.tween_property(self, "position", target, slide_duration)
	# 落地后向上轻弹，再回到同一个落点。
	slide_tween.tween_property(
		self, "position", target + Vector3.UP * bounce_height, bounce_duration
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	slide_tween.tween_property(
		self, "position", target, bounce_duration
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)


func stop_exploration() -> void:
	# 提前点击消散时，一并取消尚未开始或正在进行的移动。
	if slide_tween != null and slide_tween.is_running():
		slide_tween.kill()
