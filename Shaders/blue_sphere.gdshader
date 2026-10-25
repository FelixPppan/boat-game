shader_type spatial;

uniform vec4 base_color : source_color = vec4(0.025, 0.22, 0.8, 1.0);
uniform vec4 edge_color : source_color = vec4(0.15, 0.7, 1.0, 1.0);
uniform float edge_power : hint_range(0.5, 8.0) = 3.0;
uniform float glow_strength : hint_range(0.0, 4.0) = 0.6;
uniform float roughness : hint_range(0.0, 1.0) = 0.3;
uniform float metallic : hint_range(0.0, 1.0) = 0.15;

void fragment() {
	float edge = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), edge_power);
	ALBEDO = mix(base_color.rgb, edge_color.rgb, edge);
	EMISSION = edge_color.rgb * edge * glow_strength;
	ROUGHNESS = roughness;
	METALLIC = metallic;
}
