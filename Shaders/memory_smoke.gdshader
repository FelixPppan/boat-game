shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never;

uniform sampler2D flow_noise : repeat_enable, filter_linear;
uniform vec4 tint : source_color = vec4(1.0);
uniform float flow_speed = 0.08;
varying float variation;

void vertex() {
	variation = fract(sin(float(INSTANCE_ID) * 127.1) * 43758.5453);
	// 面向相机，同时保留粒子的尺寸和旋转。
	float angle = INSTANCE_CUSTOM.x;
	mat2 rotation = mat2(vec2(cos(angle), sin(angle)), vec2(-sin(angle), cos(angle)));
	VERTEX.xy = rotation * VERTEX.xy;
	vec3 scale = vec3(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz), length(MODEL_MATRIX[2].xyz));
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0] * scale.x,
		INV_VIEW_MATRIX[1] * scale.y,
		INV_VIEW_MATRIX[2] * scale.z,
		MODEL_MATRIX[3]);
}

void fragment() {
	float t = TIME * flow_speed;
	vec2 p = UV * 2.0 - 1.0;
	vec2 seed = vec2(variation * 4.1, variation * 7.3);
	vec2 q = UV * 0.85 + seed + vec2(t * 0.15, -t * 0.25);
	vec2 warp = vec2(texture(flow_noise, q).r, texture(flow_noise, q + vec2(0.37, 0.61)).r);
	float broad = texture(flow_noise, q + (warp - 0.5) * 0.22).r;
	float detail = texture(flow_noise, q * 2.3 + vec2(-t * 0.12, 0.0)).r;
	float cloud = broad * 0.72 + detail * 0.28;
	// 扭曲轮廓并用噪声侵蚀边缘，形成柔软的云团，而非圆斑或细条纹。
	float radius = length(p + (warp - 0.5) * 0.45);
	float envelope = 1.0 - smoothstep(0.12, 1.0, radius);
	float density = smoothstep(0.06, 0.62, envelope * (0.3 + cloud));
	vec2 border = smoothstep(vec2(0.0), vec2(0.12), UV)
		* (1.0 - smoothstep(vec2(0.88), vec2(1.0), UV));
	density *= border.x * border.y;
	vec3 color = COLOR.rgb * tint.rgb;
	ALBEDO = color * mix(0.65, 1.1, cloud);
	EMISSION = color * density * 0.06;
	ALPHA = clamp(density * COLOR.a * tint.a, 0.0, 0.85);
}
