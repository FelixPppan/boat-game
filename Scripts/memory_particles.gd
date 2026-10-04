extends GPUParticles3D

@export_range(10, 500, 10) var spark_count: int = 150
@export_range(0.005, 0.15, 0.005) var spark_size: float = 0.08
@export_range(0.05, 2.0, 0.05) var drift_speed: float = 0.25
@export var spark_color: Color = Color(0.65, 0.8, 1.0)
@export_range(0.2, 3.0, 0.1) var spark_lifetime: float = 1.8

var edge_samples: Array[Dictionary] = []
var revealing: bool = false


func _ready() -> void:
	emitting = false
	one_shot = false
	local_coords = false
	lifetime = spark_lifetime
	# 为显现尾部与消散开头的光点重叠预留容量。
	amount = spark_count * 2
	visibility_aabb = AABB(Vector3(-5, -5, -3), Vector3(10, 10, 6))
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var fade := Gradient.new()
	fade.offsets = PackedFloat32Array([0.0, 0.6, 1.0])
	fade.colors = PackedColorArray([Color(1, 1, 1, 0.7), Color.WHITE, Color(1, 1, 1, 0)])
	var ramp := GradientTexture1D.new()
	ramp.gradient = fade
	var motion := ParticleProcessMaterial.new()
	motion.gravity = Vector3(0, 0.05, 0)
	motion.scale_min = 0.5
	motion.scale_max = 1.5
	# 在每颗光点自己的寿命内逐渐缩小，同时保留原来的透明度淡出。
	var shrink := Curve.new()
	shrink.add_point(Vector2(0.0, 1.0))
	shrink.add_point(Vector2(0.25, 1.0))
	shrink.add_point(Vector2(0.7, 0.25))
	shrink.add_point(Vector2(1.0, 0.0))
	var shrink_texture := CurveTexture.new()
	shrink_texture.curve = shrink
	motion.scale_curve = shrink_texture
	motion.color_ramp = ramp
	process_material = motion

	var radial := Gradient.new()
	radial.colors = PackedColorArray([Color.WHITE, Color(1, 1, 1, 0)])
	var texture := GradientTexture2D.new()
	texture.width = 64
	texture.height = 64
	texture.gradient = radial
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(1, 0.5)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.vertex_color_use_as_albedo = true
	material.albedo_color = spark_color
	material.albedo_texture = texture
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * spark_size
	quad.material = material
	draw_pass_1 = quad
	set_process(false)


func play(layers: Array[MeshInstance3D], is_revealing: bool = false) -> void:
	# 只在 PNG 有内容的位置采样，并复用图片 Shader 的消散公式。
	set_process(false)
	edge_samples.clear()
	revealing = is_revealing
	var per_layer := maxi(1, spark_count / layers.size())
	for layer in layers:
		var material := layer.material_override as ShaderMaterial
		var picture: Texture2D = material.get_shader_parameter("picture")
		var noise_texture: Texture2D = material.get_shader_parameter("noise_texture")
		var picture_image := picture.get_image()
		if picture_image.is_compressed():
			picture_image.decompress()
		var noise_image := noise_texture.get_image()
		# 噪声贴图在后台生成，第一次点击时等待其就绪。
		if noise_image == null:
			await noise_texture.changed
			noise_image = noise_texture.get_image()
		var noise_scale: float = material.get_shader_parameter("noise_scale")
		var edge_width: float = material.get_shader_parameter("edge_width")
		var bounds := layer.mesh.get_aabb()
		var accepted := 0
		for attempt in range(per_layer * 20):
			var uv := Vector2(randf(), randf())
			var pixel := Vector2i(uv * Vector2(picture_image.get_size()))
			if picture_image.get_pixelv(pixel).a < 0.2:
				continue
			var inward := minf(minf(uv.x, 1.0 - uv.x), minf(uv.y, 1.0 - uv.y)) * 2.0
			var field := inward * 0.55 + _sample_noise(noise_image, uv * noise_scale) * 0.45
			var point := Vector3(
				bounds.position.x + uv.x * bounds.size.x,
				bounds.position.y + (1.0 - uv.y) * bounds.size.y, 0.04)
			edge_samples.append({
				"material": material,
				"birth": clampf((field - edge_width * 0.5 + 0.2) / 1.4, 0.0, 1.0),
				"transform": Transform3D(layer.global_basis, layer.to_global(point)),
				"velocity": layer.global_basis * Vector3(randf_range(-0.5, 0.5) * drift_speed, drift_speed * randf_range(0.4, 1.0), drift_speed * 0.2)
			})
			accepted += 1
			if accepted == per_layer:
				break
	set_process(true)


func _sample_noise(image: Image, uv: Vector2) -> float:
	# 重复寻址与双线性采样，使 CPU 的出生时刻贴近 Shader 的亮边。
	var point := uv * Vector2(image.get_size()) - Vector2(0.5, 0.5)
	var base := Vector2i(point.floor())
	var weight := point - point.floor()
	var x0 := posmod(base.x, image.get_width())
	var y0 := posmod(base.y, image.get_height())
	var x1 := posmod(base.x + 1, image.get_width())
	var y1 := posmod(base.y + 1, image.get_height())
	return lerpf(
		lerpf(image.get_pixel(x0, y0).r, image.get_pixel(x1, y0).r, weight.x),
		lerpf(image.get_pixel(x0, y1).r, image.get_pixel(x1, y1).r, weight.x), weight.y)


func _process(_delta: float) -> void:
	for index in range(edge_samples.size() - 1, -1, -1):
		var sample := edge_samples[index]
		var progress: float = sample.material.get_shader_parameter("progress")
		var reached: bool = progress <= sample.birth if revealing else progress >= sample.birth
		if not reached:
			continue
		var flags := EMIT_FLAG_POSITION | EMIT_FLAG_ROTATION_SCALE | EMIT_FLAG_VELOCITY
		emit_particle(sample.transform, sample.velocity, Color.WHITE, Color(), flags)
		edge_samples.remove_at(index)
	if edge_samples.is_empty():
		set_process(false)
