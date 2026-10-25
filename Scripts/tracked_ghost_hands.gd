extends Node3D
## The mitten's two finger bones follow the average of the four tracked fingers.
## Image landmarks provide screen position and approximate relative depth.

@export var smoothing: float = 18.0
@export var depth: float = 2.0

const CHAINS := {
	"left": ["lefthand", "lefthand.001", "lefthand.002", "ThumbL", "ThumbL.002", "ThumbL.003"],
	"right": ["righthand.003", "righthand.004", "righthand.005", "ThumbR.001", "ThumbR.004", "ThumbR.005"],
}
var skeleton: Skeleton3D
var hands: Dictionary = {}
@onready var camera: Camera3D = $"../Camera3D"

func _ready() -> void:
	skeleton = $Ghost.find_children("*", "Skeleton3D", true, false)[0]
	for mesh in $Ghost.find_children("*", "MeshInstance3D", true, false):
		mesh.visible = false
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for side in CHAINS:
		# The tracking stream swaps labels after mirroring the webcam.
		# Use the opposite anatomical mesh so the palm faces the viewer
		# while the thumb still follows the detected thumb side.
		var model_side := "right" if side == "left" else "left"
		var bones: Array[int] = []
		for bone_name in CHAINS[model_side]:
			bones.append(skeleton.find_bone(bone_name))
		var rest := skeleton.get_bone_global_rest(bones[0])
		var thumb := skeleton.get_bone_global_rest(bones[3]).origin
		var palm := _frame(rest.basis.y, thumb - rest.origin)
		hands[side] = {
			"bones": bones,
			"mesh": $Ghost.find_child(model_side + "_hand", true, false),
			"rest_palm": palm,
			"length": rest.origin.distance_to(skeleton.get_bone_global_rest(bones[1]).origin),
			"tracked": false,
		}
	set_active(false)

func set_active(active: bool) -> void:
	set_process(active)
	for hand in hands.values():
		hand.mesh.hide()
		hand.tracked = false

func _frame(forward: Vector3, across: Vector3) -> Basis:
	var y := forward.normalized()
	var x := (across - y * across.dot(y)).normalized()
	return Basis(x, y, x.cross(y)).orthonormalized()

func _process(delta: float) -> void:
	for side in hands:
		var points := HandTracking.get_hand(side)
		var hand: Dictionary = hands[side]
		hand.mesh.visible = not points.is_empty()
		if points.is_empty():
			hand.tracked = false
			continue
		_update_hand(hand, points, delta)

func _update_hand(hand: Dictionary, points: Array[Vector3], delta: float) -> void:
	var size := Vector2(get_viewport().size)
	var width := camera.project_position(Vector2(size.x, size.y * 0.5), depth).x * 2.0
	var positions: Array[Vector3] = []
	for point in points:
		var position_3d := camera.project_position(Vector2(point.x, point.y) * size, depth)
		position_3d.z -= (point.z - points[0].z) * width
		positions.append(skeleton.to_local(position_3d))
	var forward := positions[9] - positions[0]
	var across := positions[5] - positions[17]
	# An edge-on palm cannot define a stable orientation for this frame.
	if forward.length_squared() < 0.000001 or forward.cross(across).length_squared() < 0.00000001:
		return
	var palm := _frame(forward, across)
	var alignment: Basis = palm * hand.rest_palm.inverse()
	var weight := 1.0 - exp(-smoothing * delta) if hand.tracked else 1.0
	var bones: Array[int] = hand.bones
	var root := bones[0]
	var scale_factor: float = clampf(forward.length() / hand.length, 0.3, 6.0)
	skeleton.set_bone_pose_position(root, skeleton.get_bone_pose_position(root).lerp(positions[0], weight))
	skeleton.set_bone_pose_scale(root, skeleton.get_bone_pose_scale(root).lerp(Vector3.ONE * scale_factor, weight))
	var directions: Array[Vector3] = [forward, Vector3.ZERO, Vector3.ZERO,
		positions[2] - positions[1], positions[3] - positions[2], positions[4] - positions[3]]
	for finger in [5, 9, 13, 17]:
		directions[1] += (positions[finger + 1] - positions[finger]).normalized()
		directions[2] += (positions[finger + 2] - positions[finger + 1]).normalized()
	for i in bones.size():
		var bone := bones[i]
		var basis := alignment * skeleton.get_bone_global_rest(bone).basis.orthonormalized()
		var direction := directions[i].normalized()
		if direction.length_squared() < 0.5:
			continue
		basis = Basis(Quaternion(basis.y.normalized(), direction)) * basis
		var parent := skeleton.get_bone_parent(bone)
		if parent >= 0:
			basis = skeleton.get_bone_global_pose(parent).basis.orthonormalized().inverse() * basis
		var rotation := basis.orthonormalized().get_rotation_quaternion()
		skeleton.set_bone_pose_rotation(bone, skeleton.get_bone_pose_rotation(bone).slerp(rotation, weight))
	hand.tracked = true
