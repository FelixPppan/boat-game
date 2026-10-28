extends Node3D

# Assign the imported player after the animated model is available.
@export var animation_player: AnimationPlayer
@export var idle_animation: StringName = &"idle"
@export var forward_animation: StringName = &"row_forward"
# A forward stroke on the opposite side turns the boat.
@export var left_turn_animation: StringName = &"row_right"
@export var right_turn_animation: StringName = &"row_left"
@export var blend_time: float = 0.2

# The ghost model is mirrored across the boat's centreline so its oar is on the
# same side as the player's real oar.
# 幽灵模型沿船的中心线镜像,让它的桨和玩家手里真实的桨在同一侧。
## Defaults to the first 3D child. 不填时用第一个 3D 子节点。
@export var model: Node3D
## Side the oar is on in the unmirrored model: +1 left (port), -1 right (starboard).
## 模型未镜像时桨在哪一侧:+1 左舷,-1 右舷。
@export_enum("Right:-1", "Left:1") var model_oar_side: int = -1

# Procedural stroke: the hand and the oar swing together about the grip. Forward
# rowing pulls the blade aft through the water and returns it through the air;
# backward rowing plays the same cycle in reverse. Distances are in boat metres.
# 程序化划桨:手和桨一起绕握桨点摆动。向前划时桨叶在水里往后拉、从空中回到前面;
# 向后划时同一个周期倒着播。距离单位是船体坐标下的米。
@export_group("Stroke")
## Defaults to the model's "right_hand". 不填时用模型里的 "right_hand"。
@export var hand: Node3D
## Defaults to the model's "立方体". 不填时用模型里的 "立方体"。
@export var oar: Node3D
## The second hand is skinned, so it moves through this root bone of the model's skeleton.
## 另一只手是蒙皮网格,通过模型骨架里的这根根骨骼来带动。
@export var other_hand_bone: StringName = &"lefthand"
## Strokes per second. 每秒划几下。
@export_range(0.1, 3.0, 0.05) var stroke_rate: float = 0.9
## Fraction of the cycle the blade spends in the water.
## 一个周期里桨叶在水中的比例。
@export_range(0.2, 0.8, 0.05) var drive_fraction: float = 0.55
## How far the blade swings fore and aft of rest (degrees).
## 桨叶前后各摆多少度。
@export_range(0.0, 80.0, 1.0) var sweep_degrees: float = 32.0
## How far the blade lifts outward on the return (degrees).
## 回桨时桨叶向外抬起多少度。
@export_range(0.0, 80.0, 1.0) var lift_degrees: float = 25.0
## How far the hand reaches fore and aft of rest (m).
## 手前后各移动多少米。
@export_range(0.0, 0.5, 0.01) var hand_reach: float = 0.12
## How high the hand lifts on the return (m).
## 回桨时手抬起多少米。
@export_range(0.0, 0.5, 0.01) var hand_raise: float = 0.06
## How quickly the stroke fades in and out (1/s). 划桨动作淡入淡出的快慢(1/秒)。
@export_range(0.5, 20.0, 0.5) var blend_speed: float = 5.0

var _boat: Node
var _model_rest: Transform3D
var _mirror: Transform3D
var _mirrored := false

var _hand_rest: Transform3D
var _oar_rest: Transform3D
var _skeleton: Skeleton3D
var _bone := -1
var _bone_rest: Transform3D
var _skeleton_to_model: Transform3D
var _grip: Vector3
var _forward: Vector3
var _up: Vector3
var _sweep_axis: Vector3
var _lift_axis: Vector3
var _phase := 0.0
var _amount := 0.0
var _direction := 1.0


func _ready() -> void:
	_boat = _find_boat()
	if model == null:
		for child in get_children():
			if child is Node3D:
				model = child
				break
	if model != null and _boat != null:
		_model_rest = model.transform
		# Mirror across the boat's YZ plane, expressed in this node's frame. The
		# chain of local transforms up to the boat includes any Model node in between.
		# 船体 YZ 平面的镜像,换算到本节点坐标系。沿父链累乘到船,中间的 Model 等节点也算进去。
		var to_boat := Transform3D.IDENTITY
		var n: Node = self
		while n != _boat:
			to_boat = (n as Node3D).transform * to_boat
			n = n.get_parent()
		var flip_x := Transform3D(Basis.from_scale(Vector3(-1.0, 1.0, 1.0)), Vector3.ZERO)
		_mirror = to_boat.affine_inverse() * flip_x * to_boat
		_setup_stroke((to_boat * _model_rest).basis.inverse())
	if animation_player == null or _boat == null:
		return
	_boat.rowing_animation_changed.connect(_play_action)
	_play_action(&"idle")


func _find_boat() -> Node:
	var n := get_parent()
	while n != null and not n.has_method("oar_side"):
		n = n.get_parent()
	return n


## `boat_to_model` turns boat-frame vectors into the model's local frame. Mirroring
## leaves fore-aft and up alone, so these stay valid on either side.
## `boat_to_model` 把船体坐标的向量转到模型局部坐标。镜像不改变前后和上下,
## 所以左右两侧都适用。
func _setup_stroke(boat_to_model: Basis) -> void:
	if hand == null:
		hand = model.get_node_or_null("right_hand") as Node3D
	if oar == null:
		oar = model.get_node_or_null("立方体") as Node3D
	if hand == null or oar == null:
		return
	_hand_rest = hand.transform
	_oar_rest = oar.transform
	_grip = _hand_rest.origin
	_skeleton = model.find_child("Skeleton3D", true, false) as Skeleton3D
	if _skeleton != null:
		_bone = _skeleton.find_bone(other_hand_bone)
	if _bone >= 0:
		_bone_rest = _skeleton.get_bone_pose(_bone)
		_skeleton_to_model = Transform3D.IDENTITY
		var n: Node = _skeleton
		while n != model:
			_skeleton_to_model = (n as Node3D).transform * _skeleton_to_model
			n = n.get_parent()
	_forward = boat_to_model * Vector3.FORWARD
	_up = boat_to_model * Vector3.UP
	# Positive angles swing the blade (below the grip) forward, and outward.
	# 正角度让握桨点下方的桨叶向前摆、向外抬。
	var outward := Vector3(-model_oar_side, 0.0, 0.0)
	_sweep_axis = (boat_to_model * Vector3.RIGHT).normalized()
	_lift_axis = (boat_to_model * outward.cross(Vector3.UP)).normalized()


func _process(delta: float) -> void:
	if model == null or _boat == null:
		return
	_update_side()
	_update_stroke(delta)


func _update_side() -> void:
	var side: float = _boat.oar_side()
	if side == 0.0:
		return
	var mirrored := signf(side) != float(model_oar_side)
	if mirrored != _mirrored:
		_mirrored = mirrored
		model.transform = _mirror * _model_rest if mirrored else _model_rest


func _update_stroke(delta: float) -> void:
	if hand == null or oar == null or not _boat.has_method("rowing_drive"):
		return
	var drive: float = _boat.rowing_drive()
	if drive != 0.0:
		_direction = signf(drive)
	_amount = lerpf(_amount, 1.0 if drive != 0.0 else 0.0, 1.0 - exp(-blend_speed * delta))
	if _amount > 0.01:
		_phase = fposmod(_phase + _direction * stroke_rate * delta, 1.0)

	# Normalised pose at this point of the cycle: +1 is the catch (forward).
	# 周期这一点上的归一化姿势:+1 是入水点(最前)。
	var sweep: float
	var lift: float
	var raise: float
	if _phase < drive_fraction:
		var s := _phase / drive_fraction
		sweep = lerpf(1.0, -1.0, smoothstep(0.0, 1.0, s))
		lift = 0.0
		raise = -0.3 * sin(PI * s)
	else:
		var r := (_phase - drive_fraction) / (1.0 - drive_fraction)
		sweep = lerpf(-1.0, 1.0, smoothstep(0.0, 1.0, r))
		lift = sin(PI * r)
		raise = sin(PI * r)

	var rot := Basis(_lift_axis, deg_to_rad(lift_degrees) * lift * _amount) \
		* Basis(_sweep_axis, deg_to_rad(sweep_degrees) * sweep * _amount)
	var offset := (_forward * hand_reach * sweep + _up * hand_raise * raise) * _amount
	var rig := Transform3D(rot, _grip + offset) * Transform3D(Basis.IDENTITY, -_grip)
	hand.transform = rig * _hand_rest
	oar.transform = rig * _oar_rest
	if _bone >= 0:
		# A root bone's pose is in skeleton space, so carry the rig over to it.
		# 根骨骼的姿势在骨架空间里,所以把同一个变换换算过去。
		var rig_in_skeleton := _skeleton_to_model.affine_inverse() * rig * _skeleton_to_model
		_skeleton.set_bone_pose(_bone, rig_in_skeleton * _bone_rest)


func _play_action(action: StringName) -> void:
	var clip: StringName = idle_animation
	match action:
		&"forward": clip = forward_animation
		&"left": clip = left_turn_animation
		&"right": clip = right_turn_animation
	animation_player.play(clip, blend_time)
