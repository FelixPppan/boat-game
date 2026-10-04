extends Node3D
## Stern trail history: waterline intersection written into a decaying buffer.
## Visual aurora mist is entirely in waves.gdshader.

@export_group("Buffer")
@export var world_size: float = 100.0
@export var world_center: Vector2 = Vector2.ZERO
@export_range(128, 512, 64) var resolution: int = 256

@export_group("History")
## Closer to 1 = longer trail (per 1/60 s).
@export_range(0.90, 0.999, 0.001) var decay: float = 0.993
@export_range(0.0, 1.5, 0.05) var write_strength: float = 1.0

@export_group("Hull waterline")
@export var hull_radius_x: float = 0.55
@export var hull_radius_z: float = 1.35
@export var hull_top_local_y: float = 0.35
@export var hull_bottom_local_y: float = -0.55
@export var intersection_band: float = 0.25
@export_range(0.05, 0.4, 0.01) var edge_band: float = 0.16
@export var scan_padding_m: float = 0.35
## Only paint from this local Z toward the stern (+Z). Bow = -Z.
@export var stern_z_start: float = 0.05

@export_group("Motion")
@export var min_paint_speed: float = 0.08
@export var full_paint_speed: float = 0.7

@export_group("Clear")
const CLEAR_KEY := KEY_F4

var _boat: Node3D = null
var _water: Node = null
var _img: Image
var _tex: ImageTexture
var _water_mat: ShaderMaterial = null
var _bytes: PackedByteArray
var external_speed: float = 0.0
var _mask_bound: bool = false


func setup(boat: Node3D) -> void:
	_boat = boat


func _ready() -> void:
	_img = Image.create(resolution, resolution, false, Image.FORMAT_RGBA8)
	_img.fill(Color(0, 0, 0, 1))
	_bytes = _img.get_data()
	_tex = ImageTexture.create_from_image(_img)
	call_deferred("_bind_and_push")


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == CLEAR_KEY:
		clear()


func clear() -> void:
	if _img == null:
		return
	_img.fill(Color(0, 0, 0, 1))
	_bytes = _img.get_data()
	_tex.set_image(_img)


func _process(delta: float) -> void:
	if _boat == null or _img == null:
		return
	if _water == null:
		_resolve_water()

	_fade(pow(decay, delta * 60.0))

	var speed := maxf(external_speed, 0.0)
	var factor := smoothstep(min_paint_speed, full_paint_speed, speed)
	if factor > 0.001:
		_paint_intersection(factor)

	_img.set_data(resolution, resolution, false, Image.FORMAT_RGBA8, _bytes)
	_tex.set_image(_img)
	_push_uniforms()

func _resolve_water() -> void:
	_water = get_tree().get_first_node_in_group("water_plane")
	if _water == null:
		_water = get_node_or_null("/root/Map/WaterPlane")


func _fade(mult: float) -> void:
	var n := resolution * resolution
	for p in n:
		var i := p * 4
		var r := float(_bytes[i]) * mult
		if r < 0.8:
			_bytes[i] = 0
		else:
			_bytes[i] = int(r)


func _paint_intersection(factor: float) -> void:
	var half := maxf(hull_radius_x, hull_radius_z) + scan_padding_m
	var boat_basis := _boat.global_transform.basis
	var origin := _boat.global_position
	var corners: Array[Vector2] = [
		_xz(origin + boat_basis * Vector3(-half, 0, -half)),
		_xz(origin + boat_basis * Vector3(half, 0, -half)),
		_xz(origin + boat_basis * Vector3(-half, 0, half)),
		_xz(origin + boat_basis * Vector3(half, 0, half)),
	]
	var min_x := corners[0].x
	var max_x := corners[0].x
	var min_z := corners[0].y
	var max_z := corners[0].y
	for c in corners:
		min_x = minf(min_x, c.x)
		max_x = maxf(max_x, c.x)
		min_z = minf(min_z, c.y)
		max_z = maxf(max_z, c.y)

	var w := resolution
	var uv0 := _world_to_uv(min_x, min_z)
	var uv1 := _world_to_uv(max_x, max_z)
	var px0 := clampi(int(floor(minf(uv0.x, uv1.x) * float(w))), 0, w - 1)
	var px1 := clampi(int(ceil(maxf(uv0.x, uv1.x) * float(w))), 0, w - 1)
	var py0 := clampi(int(floor(minf(uv0.y, uv1.y) * float(w))), 0, w - 1)
	var py1 := clampi(int(ceil(maxf(uv0.y, uv1.y) * float(w))), 0, w - 1)

	var inv := _boat.global_transform.affine_inverse()
	var water_base_y := 0.0
	if _water is Node3D:
		water_base_y = (_water as Node3D).global_position.y
	var band := maxf(intersection_band, 0.05)
	var rx := maxf(hull_radius_x, 0.001)
	var rz := maxf(hull_radius_z, 0.001)

	for py in range(py0, py1 + 1):
		for px in range(px0, px1 + 1):
			var wx := (float(px) / float(w) - 0.5) * world_size + world_center.x
			var wz := (float(py) / float(w) - 0.5) * world_size + world_center.y
			var local: Vector3 = inv * Vector3(wx, origin.y, wz)
			# Stern only (+Z); discard bow half.
			if local.z < stern_z_start:
				continue
			var ex := local.x / rx
			var ez := local.z / rz
			var e2 := ex * ex + ez * ez
			if e2 > 1.0 + edge_band * 2.0:
				continue

			# Soft filled stern body (continuous ribbon) + thin waterline edge boost.
			var edge := 1.0 - absf(e2 - 1.0) / edge_band
			edge = clampf(edge, 0.0, 1.0)
			var fill := smoothstep(1.0 + edge_band, 0.15, e2) # 1 near centre, 0 outside
			var shape := maxf(edge, fill * 0.85)
			if shape <= 0.001:
				continue

			var water_y := water_base_y
			if _water != null and _water.has_method("get_height"):
				water_y += float(_water.get_height(Vector3(wx, 0.0, wz)))
			var over := clampf((origin.y + hull_top_local_y - water_y) / band, 0.0, 1.0)
			var under := clampf((water_y - (origin.y + hull_bottom_local_y)) / band, 0.0, 1.0)
			# Never fully kill paint by wave height — keeps history solid in troughs later.
			var waterline := over * under
			var height_w := lerpf(0.55, 1.0, waterline)
			var stern_w := smoothstep(stern_z_start, stern_z_start + rz * 0.85, local.z)
			var foam := shape * height_w * stern_w * write_strength * factor
			if foam <= 0.001:
				continue
			var i := (py * w + px) * 4
			var b := int(clampf(foam, 0.0, 1.0) * 255.0)
			if b > _bytes[i]:
				_bytes[i] = b


func _xz(v: Vector3) -> Vector2:
	return Vector2(v.x, v.z)


func _world_to_uv(wx: float, wz: float) -> Vector2:
	return Vector2(
		(wx - world_center.x) / world_size + 0.5,
		(wz - world_center.y) / world_size + 0.5
	)


func _bind_and_push() -> void:
	_bind_material()
	_push_uniforms()


func _bind_material() -> void:
	var water := get_tree().get_first_node_in_group("water_plane")
	if water == null:
		water = get_node_or_null("/root/Map/WaterPlane")
	if water is MeshInstance3D:
		var mi := water as MeshInstance3D
		var mat := mi.get_surface_override_material(0)
		if mat == null:
			mat = mi.material_override
		if mat is ShaderMaterial:
			_water_mat = mat as ShaderMaterial


func _push_uniforms() -> void:
	if _water_mat == null:
		_bind_material()
	if _water_mat == null:
		return
	if not _mask_bound:
		_water_mat.set_shader_parameter("trail_mask", _tex)
		_mask_bound = true
	_water_mat.set_shader_parameter("trail_world_center", world_center)
	_water_mat.set_shader_parameter("trail_world_size", world_size)
