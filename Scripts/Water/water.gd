extends MeshInstance3D

var shader_material
var time: float = 0.0
var speed: float = 1.0


# Displacement map
@onready var displacement_map: ColorRect = get_node("/root/Map/Water/DisplacementViewport/DisplacementColorRect")

# Noise
var noise: NoiseTexture2D
var noise_intensity: float

# Gerstner settings
var gerstner_wave_1: Vector4
var gerstner_wave_2: Vector4
var gerstner_wave_3: Vector4
var gerstner_wave_4: Vector4

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
	
	var gw1 = shader_material.get_shader_parameter("gerstner_wave_1")
	var gw2 = shader_material.get_shader_parameter("gerstner_wave_2")
	var gw3 = shader_material.get_shader_parameter("gerstner_wave_3")
	var gw4 = shader_material.get_shader_parameter("gerstner_wave_4")
	gerstner_wave_1 = gw1 if gw1 != null else Vector4(1, 1, 1, 1)
	gerstner_wave_2 = gw2 if gw2 != null else Vector4(1, 0, 1, 0)
	gerstner_wave_3 = gw3 if gw3 != null else Vector4(1, 0, 1, 0)
	gerstner_wave_4 = gw4 if gw4 != null else Vector4(1, 0, 1, 0)

# Re-implementation of Gerstner wave function in GDScript
# Tangent and binormal are not included, as they are only needed for lighting (calculating the surface normal)
func gerstner(wavelength: float, steepness: float, dir: Vector2, p: Vector3):
	var k: float = (2.0 * PI) / wavelength # Wave number 
	var g: float = 9.8337 # Gravity constant
	var c: float = sqrt(g/k) # Phase speed
	
	var d: Vector2 = dir.normalized() # Direction
	
	var f: float = k * d.dot(Vector2(p.x, p.z)) - c * time * speed # Function inside sin/cos wave	
	var a: float = steepness / k
	
	var wave_noise: float = 0 # = texture(noise, p.xz / 100.0 + dir * time * 0.01).r * noise_intensity - noise_intensity / 2.0
	
	var x: float = d.x * (a * cos(f))
	var y: float = a * sin(f) + wave_noise
	var z: float = d.y * (a * cos(f))
	
	return Vector3(x, y, z)

# Re-implementation of create_wave function in GDScript
func get_height(point: Vector3):
	# Gersner Wave 1
	point = gerstner(gerstner_wave_1.x, gerstner_wave_1.y, Vector2(gerstner_wave_1.z, gerstner_wave_1.w), point)
	point += gerstner(gerstner_wave_1.x * 0.8, gerstner_wave_1.y * 0.5, Vector2(gerstner_wave_1.z * 0.5, gerstner_wave_1.w *1.5), point)
	point += gerstner(gerstner_wave_1.x * 0.5, gerstner_wave_1.y * 1.5, Vector2(gerstner_wave_1.z * 0.5, gerstner_wave_1.w *1.5), point)
	point += gerstner(gerstner_wave_1.x * 0.5, gerstner_wave_1.y * 1.5, Vector2(gerstner_wave_1.z * 0.5, gerstner_wave_1.w), point)
	
	# Gersner Wave 2
	point += gerstner(gerstner_wave_2.x, gerstner_wave_2.y, Vector2(gerstner_wave_2.z, gerstner_wave_2.w), point)
	point += gerstner(gerstner_wave_2.x * 0.5, gerstner_wave_2.y * 1.5, Vector2(gerstner_wave_2.z * 0.5, gerstner_wave_2.w *1.5), point)
	point += gerstner(gerstner_wave_2.x * 0.8, gerstner_wave_2.y * 0.5, Vector2(gerstner_wave_2.z * 0.5, gerstner_wave_2.w *1.5), point)
	
	# Gersner Wave 3
	point += gerstner(gerstner_wave_3.x, gerstner_wave_3.y, Vector2(gerstner_wave_3.z, gerstner_wave_3.w), point)
	point += gerstner(gerstner_wave_3.x * 0.5, gerstner_wave_3.y * 1.5, Vector2(gerstner_wave_3.z * 0.5, gerstner_wave_3.w *1.5), point)
	point += gerstner(gerstner_wave_3.x * 0.8, gerstner_wave_3.y * 0.5, Vector2(gerstner_wave_3.z * 0.5, gerstner_wave_3.w *1.5), point)
	
	# Gersner Wave 4
	point += gerstner(gerstner_wave_4.x, gerstner_wave_4.y, Vector2(gerstner_wave_4.z, gerstner_wave_4.w), point)
	point += gerstner(gerstner_wave_4.x * 0.5, gerstner_wave_4.y * 1.5, Vector2(gerstner_wave_4.z * 0.5, gerstner_wave_4.w *1.5), point)
	point += gerstner(gerstner_wave_4.x * 0.8, gerstner_wave_4.y * 0.5, Vector2(gerstner_wave_4.z * 1.5, gerstner_wave_4.w *0.5), point)
	return point.y

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	time += delta
	if shader_material != null:
		shader_material.set_shader_parameter("time", time)
		shader_material.set_shader_parameter("speed", speed)
