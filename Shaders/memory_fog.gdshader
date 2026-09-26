shader_type fog;

uniform sampler3D cloud_noise : repeat_enable, filter_linear;
uniform vec4 fog_color : source_color = vec4(0.65, 0.76, 0.92, 1.0);
uniform float density : hint_range(0.0, 4.0) = 1.4;
uniform float flow_speed : hint_range(0.0, 0.3) = 0.015;
uniform float detail_scale : hint_range(0.5, 4.0) = 1.3;
uniform float warp_strength : hint_range(0.0, 0.5) = 0.18;
uniform float fog_opacity : hint_range(0.0, 1.0) = 1.0;
uniform float glow_strength : hint_range(0.0, 1.0) = 0.35;
uniform float grain_strength : hint_range(0.0, 1.0) = 0.4;
uniform float grain_scale : hint_range(1.0, 6.0) = 2.0;
uniform float contrast : hint_range(1.0, 4.0) = 1.4;

void fog() {
	vec3 p = UVW;
	float t = TIME * flow_speed;
	vec3 q = p * detail_scale + vec3(t * 0.3, -t, t * 0.2);
	// 三维 Simplex 噪声扭曲三维采样坐标，减少规则网格方向感。
	vec3 warp = vec3(
		texture(cloud_noise, q * 0.7).r,
		texture(cloud_noise, q * 0.7 + vec3(0.31, 0.57, 0.13)).r,
		texture(cloud_noise, q * 0.7 + vec3(0.71, 0.19, 0.43)).r
	) - 0.5;
	float broad = texture(cloud_noise, q + warp * warp_strength).r;
	float detail = texture(cloud_noise, q * 1.9 - vec3(t * 0.1, 0.0, t * 0.2)).r;
	float cloud = mix(broad, detail, 0.2);
	// 细节附着在三维空间中缓慢移动，不使用逐帧随机闪烁的噪点。
	// 细颗粒单独缓慢漂移，频率增大时不再同时放大移动速度。
	vec3 grain_position = p * detail_scale * grain_scale + vec3(t * 0.08, -t * 0.12, 0.0);
	float grain = texture(cloud_noise, grain_position + warp * 0.1).r;
	cloud = clamp((cloud - 0.5) * contrast + 0.5, 0.0, 1.0);
	// 雾分布在有厚度的椭球内部，不再是带透明度的平面。
	float radius = length((p - 0.5) * 2.0 + warp * 0.12);
	float envelope = 1.0 - smoothstep(0.25, 0.95, radius);
	float amount = smoothstep(0.2, 0.75, cloud) * envelope;
	amount *= mix(1.0, smoothstep(0.15, 0.85, grain) * 1.6, grain_strength);
	DENSITY = amount * density * fog_opacity;
	ALBEDO = fog_color.rgb;
	EMISSION = fog_color.rgb * glow_strength * mix(0.85, 1.05, broad);
}
