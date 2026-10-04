shader_type spatial;
render_mode unshaded, cull_disabled;

uniform sampler2D picture : source_color;
uniform sampler2D noise_texture : repeat_enable;

uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform float noise_scale : hint_range(0.5, 8.0) = 1.5;
uniform float edge_width : hint_range(0.005, 0.15) = 0.04;
uniform float edge_strength : hint_range(0.0, 8.0) = 2.0;
uniform vec4 edge_color : source_color = vec4(0.65, 0.8, 1.0, 1.0);


void fragment() {
	vec4 image = texture(picture, UV);
	float noise_value = texture(noise_texture, UV * noise_scale).r;

	// 越靠近画布边缘，数值越小。
	vec2 distance_to_edge = min(UV, vec2(1.0) - UV);
	float inward = min(distance_to_edge.x, distance_to_edge.y) * 2.0;

	// 把向内推进的趋势与不规则噪声混合。
	float field = inward * 0.55 + noise_value * 0.45;

	// 留出余量，保证起点完整、终点完全消失。
	float threshold = mix(-0.2, 1.2, progress);
	float remaining = field - threshold;

	float visible_mask = smoothstep(0.0, 0.025, remaining);

	// 在即将消失的位置形成一道亮边。
	float edge = 1.0 - smoothstep(0.0, edge_width, remaining);
	edge *= visible_mask;

	ALBEDO = mix(image.rgb, edge_color.rgb, edge);
	EMISSION = edge_color.rgb * edge * edge_strength;
	ALPHA = image.a * visible_mask;
}
