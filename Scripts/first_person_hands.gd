extends CanvasLayer

@onready var display: TextureRect = $Display
@onready var viewport: SubViewport = $HandsViewport
@onready var rig: Node3D = $HandsViewport/HandRig

func _ready() -> void:
	get_viewport().size_changed.connect(_resize)
	_resize()
	set_active(false)

func _resize() -> void:
	viewport.size = Vector2i(get_viewport().get_visible_rect().size)

func set_active(active: bool) -> void:
	display.visible = active
	rig.set_active(active)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if active else SubViewport.UPDATE_DISABLED
