shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back;

// Screen-space glass: refracts the opaque scene behind the fragment.
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform vec4 glass_tint : source_color = vec4(0.76, 0.93, 1.0, 1.0);
uniform float rainbow_strength : hint_range(0.0, 1.0) = 0.65;
uniform float rainbow_scale : hint_range(0.1, 5.0) = 1.2;
uniform float color_speed : hint_range(0.0, 0.5) = 0.035;
uniform float refraction_strength : hint_range(0.0, 0.1) = 0.018;
uniform float dispersion : hint_range(0.0, 0.03) = 0.004;
uniform float center_opacity : hint_range(0.0, 1.0) = 0.24;
uniform float edge_opacity : hint_range(0.0, 1.0) = 0.78;
uniform float gradient_strength : hint_range(0.0, 0.8) = 0.18;
uniform float glow_strength : hint_range(0.0, 3.0) = 0.45;
uniform float roughness : hint_range(0.0, 1.0) = 0.12;

varying vec3 local_position;

void vertex() {
	local_position = VERTEX;
}

void fragment() {
	vec3 normal = normalize(NORMAL);
	float facing = clamp(dot(normal, normalize(VIEW)), 0.0, 1.0);
	float rim = pow(1.0 - facing, 2.5);
	float phase = (1.0 - facing) * 1.15
		+ dot(local_position, vec3(0.23, 0.37, 0.19)) * rainbow_scale
		+ dot(normal, vec3(0.17, 0.29, 0.11)) + TIME * color_speed;
	vec3 rainbow = 0.5 + 0.5 * cos(6.2831853 * (phase + vec3(0.0, 0.666667, 0.333333)));
	vec3 tint = mix(glass_tint.rgb, rainbow, rainbow_strength);
	vec2 offset = normal.xy * refraction_strength;
	vec2 split = normal.xy * dispersion;
	vec2 margin = vec2(2.0) / VIEWPORT_SIZE;
	vec2 uv = SCREEN_UV - offset;
	vec3 background;
	background.r = textureLod(screen_texture, clamp(uv + split, margin, vec2(1.0) - margin), 0.0).r;
	background.g = textureLod(screen_texture, clamp(uv, margin, vec2(1.0) - margin), 0.0).g;
	background.b = textureLod(screen_texture, clamp(uv - split, margin, vec2(1.0) - margin), 0.0).b;
	float gradient = 0.5 + 0.5 * sin(local_position.y * rainbow_scale * 2.0);
	float opacity = clamp(mix(center_opacity, edge_opacity, rim)
		+ (gradient - 0.5) * gradient_strength, 0.02, 1.0);
	// Keep the sampled background in emission to avoid lighting it a second time.
	ALBEDO = tint * 0.32;
	EMISSION = background * mix(vec3(1.0), tint, 0.22) * 0.72
		+ tint * glow_strength * (0.12 + rim);
	ROUGHNESS = roughness;
	METALLIC = 0.0;
	SPECULAR = 0.75;
	ALPHA = opacity;
}
