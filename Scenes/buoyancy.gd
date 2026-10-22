"""
Heavily inspired by the below implementation
https://www.youtube.com/watch?v=_R2KDcAp1YQ
"""

extends RigidBody3D

@onready var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
@onready var water = get_node_or_null("../WaterPlane")
@onready var buoyancyPoints = $BuoyancyPoints.get_children()

@export var float_force: float = 1.0
@export var water_drag: float = 0.05
@export var water_drag_angular: float = 0.05

var submerged: bool = false

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	if water == null or not water.has_method("get_height"):
		push_error("Buoyancy requires a sibling WaterPlane with get_height().")
		set_physics_process(false)

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass

func _physics_process(delta: float) -> void:
	submerged = false
	for point in buoyancyPoints:
		var water_height: float = water.get_height(point.global_position);
		var depth: float = water_height - point.global_position.y; # water.get_water(global_position)
		if  depth > 0:
			submerged = true
			apply_force(Vector3.UP * float_force * gravity * depth, point.global_position - global_position) # Position is offset from body origin in global coordinates 
			# apply_central_force(Vector3.UP * float_force * gravity * depth)

func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if submerged:
		state.linear_velocity *= 1 - water_drag
		state.angular_velocity *= 1 - water_drag_angular
