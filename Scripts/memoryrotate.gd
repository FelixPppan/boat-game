extends Node3D

## 每秒旋转角度
@export var rotation_speed: float = 15.0
## 上下浮动幅度，单位：米
@export var float_height: float = 0.15
## 完成一次上下浮动需要的秒数
@export_range(0.1, 20.0) var float_period: float = 4.0

## Automatically use the combined mesh bounds as the rotation center.
@export var auto_center: bool = true
## Optional center in this node's local coordinates when auto_center is off.
@export var pivot_offset: Vector3 = Vector3.ZERO

var _pivot: Vector3
var _center: Vector3
var _initial_basis: Basis
var _elapsed: float = 0.0


func _ready() -> void:
	_pivot = pivot_offset
	if auto_center:
		var bounds: Array[AABB] = []
		_collect_bounds(self, Transform3D.IDENTITY, bounds)
		if not bounds.is_empty():
			var combined: AABB = bounds[0]
			for index in range(1, bounds.size()):
				combined = combined.merge(bounds[index])
			_pivot = combined.get_center()
	_initial_basis = basis
	_center = transform * _pivot


func _collect_bounds(node: Node, relative: Transform3D, bounds: Array[AABB]) -> void:
	if node is MeshInstance3D and node.mesh != null:
		bounds.append(relative * node.get_aabb())
	for child in node.get_children():
		if child is Node3D:
			_collect_bounds(child, relative * child.transform, bounds)


func _process(delta: float) -> void:
	_elapsed += delta
	var turn := Basis(Vector3.UP, deg_to_rad(rotation_speed) * _elapsed)
	var rotated_basis := turn * _initial_basis
	var bob := Vector3.UP * sin(_elapsed * TAU / maxf(float_period, 0.1)) * float_height
	# Compensate for the imported mesh offset so its center stays in place.
	transform = Transform3D(rotated_basis, _center + bob - rotated_basis * _pivot)
