extends MeshInstance3D

var shader_material
var time: float = 0.0
var speed: float = 1.0


# Displacement map
# @onready var displacement_map = $DisplacementColorRect.material
@onready var displacement_map: ColorRect = get_node("/root/Map/Water/DisplacementViewport/DisplacementColorRect")

# Noise
var noise: NoiseTexture2D
var noise_intensity: float

# Gerstner settings
var gerstner_wave: Vector4

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	add_to_group("water_plane")
	shader_material = displacement_map.material
	if shader_material == null:
		shader_material = material_override
	if shader_material == null:
		push_warning("WaterPlane: no ShaderMaterial")
		return
	noise = shader_material.get_shader_parameter("noise")
	var ni = shader_material.get_shader_parameter("noise_intensity")
	noise_intensity = float(ni) if ni != null else 0.2
	var gw = shader_material.get_shader_parameter("gerstner_wave")
	gerstner_wave = gw if gw != null else Vector4(1, 1, 1, 1)

# Re-implementation of Gerstner wave function in GDScript
# Tangent and binormal are not included, as they are only needed for lighting (calculating the surface normal)
func gerstner(wavelength: float, steepness: float, dir: Vector2, p: Vector3):
	var k: float = (2.0 * PI) / wavelength # Wave number 
	var g: float = 9.8337 # Gravity constant
	var c: float = sqrt(g/k) # Phase speed
	
	var d: Vector2 = dir.normalized() # Direction
	
	var f: float = k * d.dot(Vector2(p.x, p.z)) - c * time * speed; # Function inside sin/cos wave	
	var a: float = steepness / k;
	
	var wave_noise: float = 0 # = texture(noise, p.xz / 100.0 + dir * time * 0.01).r * noise_intensity - noise_intensity / 2.0;
	
	var x: float = d.x * (a * cos(f));
	var y: float = a * sin(f) + wave_noise;
	var z: float = d.y * (a * cos(f));
	
	return Vector3(x, y, z)

# Re-implementation of create_wave function in GDScript
func create_wave(p: Vector3):
	return gerstner(gerstner_wave.x, gerstner_wave.y, Vector2(gerstner_wave.z, gerstner_wave.w), p)

func get_height(point: Vector3):
	# var x: float = point.x
	# var z: float = point.z
	point = gerstner(gerstner_wave.x, gerstner_wave.y, Vector2(gerstner_wave.z, gerstner_wave.w), point)
	return point.y;

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	time += delta
	if shader_material != null:
		shader_material.set_shader_parameter("time", time)
		shader_material.set_shader_parameter("speed", speed)
