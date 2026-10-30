shader_type fog;

uniform sampler3D noise_texture : repeat_enable;
uniform vec3 fog_color : source_color = vec3(0.714, 0.694, 0.812);
uniform float density = 0.0;

void fog() {
	// One shared noise sample, with the same soft lavender as the water mist.
	float n = texture(noise_texture, WORLD_POSITION * 0.14
		+ vec3(TIME * 0.018, TIME * 0.008, TIME * 0.006)).r;
	vec3 edge_distance = abs(UVW * 2.0 - 1.0);
	vec3 fade = vec3(1.0) - smoothstep(vec3(0.35), vec3(1.0), edge_distance);
	float mask = fade.x * fade.y * fade.z;
	DENSITY = density * mix(0.5, 1.0, smoothstep(0.15, 0.85, n)) * mask;
	ALBEDO = fog_color;
	EMISSION = fog_color * 0.4 * mask;
}
