shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;

uniform vec4 fog_color : source_color = vec4(0.65, 0.76, 0.92, 1.0);
uniform float density : hint_range(0.0, 2.0) = 1.15;
uniform float flow_speed : hint_range(0.0, 0.3) = 0.07;
uniform float detail_scale : hint_range(1.0, 8.0) = 3.5;


// 生成伪随机数。
float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}


// 平滑噪声，用来形成雾的浓淡。
float noise(vec2 p) {
	vec2 cell = floor(p);
	vec2 local = fract(p);
	vec2 blend = local * local * (3.0 - 2.0 * local);

	float a = hash(cell);
	float b = hash(cell + vec2(1.0, 0.0));
	float c = hash(cell + vec2(0.0, 1.0));
	float d = hash(cell + vec2(1.0, 1.0));

	return mix(
		mix(a, b, blend.x),
		mix(c, d, blend.x),
		blend.y
	);
}


// 叠加不同大小的噪声，增加细节。
float cloud_noise(vec2 p) {
	float value = 0.0;
	float weight = 0.5;

	for (int i = 0; i < 4; i++) {
		value += noise(p) * weight;
		p = p * 2.03 + vec2(13.1, 7.7);
		weight *= 0.5;
	}

	return value;
}


void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float t = TIME * flow_speed;

	// 两层噪声朝不同方向流动。
	float first = cloud_noise(
		p * detail_scale + vec2(t, -t * 0.6)
	);
	float second = cloud_noise(
		p * detail_scale * 1.6 + vec2(-t * 0.7, t * 0.4)
	);

	// 打破规则的圆形边缘。
	float radius = length(p);
	float uneven_radius = radius + (first - 0.5) * 0.32;
	float silhouette = 1.0 - smoothstep(0.3, 0.95, uneven_radius);

	// 确保平面边缘完全透明，避免出现矩形。
	float edge_fade = 1.0 - smoothstep(0.82, 1.0, radius);

	float cloud = mix(first, second, 0.4);
	float opacity = silhouette * edge_fade;
	opacity *= smoothstep(0.18, 0.75, cloud) * density;

	ALBEDO = fog_color.rgb * (0.8 + cloud * 0.35);

	// 保留现有脚本控制的淡出。
	ALPHA *= clamp(opacity * fog_color.a, 0.0, 1.0);
}