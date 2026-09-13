extends Node3D
## Ticker-tape trail: drops a green dot every DOT_INTERVAL seconds at the
## boat's position.
##
## The dots are evenly spaced in TIME rather than in distance, which is the
## whole point -- the gap between two neighbouring dots is proportional to how
## fast the boat was going across that interval. Dots bunched together mean
## slow, dots strung out mean fast, and the chain itself is the path actually
## travelled. Exactly how a ticker-tape timer reads out motion.
##
## boat.gd creates this in code and parents it to the boat, but every dot has
## top_level = true so it ignores the boat's transform and stays put where it
## was dropped instead of being dragged along.

# ------------------------------------------- Tuning / 调参 (中英对照) ------
## Seconds between dots. Smaller gives a finer-grained record of the speed.
## 两点之间的时间间隔(秒)。调小,速度的记录就更细。
const DOT_INTERVAL := 0.2
## How many dots stay in the world. Once the ring is full the oldest dot is
## reused for the newest, so the trail never grows without bound.
## 场上最多留多少个点。满了以后最旧的坑位拿来放新点,轨迹不会无限增长。
const MAX_DOTS := 150
## World-space height of the dots. The water plane sits at y ~ -0.01 and the
## boat's origin at y ~ 0.44, so this floats just above the surface.
## 点的世界高度。水面在 y ≈ -0.01,船的坐标原点在 y ≈ 0.44,
## 这里取贴着水面上方一点点。
const DOT_HEIGHT := 0.06
## Dot radius in metres.
## 点的半径(米)。
const DOT_RADIUS := 0.13
## Dot colour. Unshaded, so the dots stay bright whatever the scene lighting.
## 点的颜色。用无光照材质,不受场景灯光影响,始终醒目。
const DOT_COLOR := Color(0.10, 1.0, 0.25)
## Key that wipes the trail.
## 清空轨迹的按键。
const CLEAR_KEY := KEY_F3

## The node whose path is being recorded.
var _target: Node3D = null
## Every dot, allocated once up front and then reused round-robin.
var _dots: Array[MeshInstance3D] = []
## Next slot of the ring to write into.
var _head := 0
## Seconds left until the next dot.
var _countdown := 0.0


func _ready() -> void:
	var mesh := SphereMesh.new()
	mesh.radius = DOT_RADIUS
	mesh.height = DOT_RADIUS * 2.0
	mesh.radial_segments = 8
	mesh.rings = 4

	var mat := StandardMaterial3D.new()
	mat.albedo_color = DOT_COLOR
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	# Allocated up front rather than spawned on demand: no allocation while
	# playing, and the ring buffer below becomes a plain index bump.
	for i in MAX_DOTS:
		var dot := MeshInstance3D.new()
		dot.mesh = mesh
		# material_override instead of setting a surface material, so this
		# needs no knowledge of how many surfaces the mesh happens to have.
		dot.material_override = mat
		dot.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		dot.visible = false
		add_child(dot)
		# Without this the dot would inherit the boat's transform and slide
		# along with it; with it, the `position` set in _spawn() is a world
		# coordinate.
		dot.top_level = true
		_dots.append(dot)


## Points the trail at the node whose path it should record. Called by boat.gd
## right after this node enters the tree.
func setup(target: Node3D) -> void:
	_target = target


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == CLEAR_KEY:
		clear()


func clear() -> void:
	for dot in _dots:
		dot.visible = false
	_head = 0
	_countdown = 0.0


func _physics_process(delta: float) -> void:
	if _target == null or delta <= 0.0:
		return

	_countdown -= delta
	if _countdown > 0.0:
		return

	_countdown += DOT_INTERVAL
	if _countdown <= 0.0:
		# The frame was long enough to miss more than one slot (the window was
		# dragged, the game was paused). Rather than dumping a pile of dots on
		# one spot, resync to the next slot.
		_countdown = DOT_INTERVAL

	_spawn()


func _spawn() -> void:
	var dot := _dots[_head]
	_head = (_head + 1) % MAX_DOTS

	# Planar position only: the boat does not change height, and a flat trail
	# on the water reads much better than one that follows every bob.
	var p := _target.global_position
	dot.position = Vector3(p.x, DOT_HEIGHT, p.z)
	dot.visible = true
