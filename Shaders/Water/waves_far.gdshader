// Outer sea around the 100 x 100 play area. Same Gerstner waves as waves.gdshader
// (world space, so the two meet without a seam). Only the far end fades to
// transparent so the horizon melts into the sky. Wave/colour values are copied
// from the main water material by far_water.gd.
// 主海面外圈。浪和 waves.gdshader 相同(按世界坐标,接缝处连续),只在最远处变透明,
// 让天际线融进天空。浪和颜色参数由 far_water.gd 从主海面材质复制过来。

shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back;

uniform vec3 albedo : source_color;
uniform vec3 albedo_high : source_color;
uniform float blend_from : hint_range(-1.0, 0.0) = -0.1;
uniform float blend_to : hint_range(0.0, 1.0) = 0.1;
uniform float metallic : hint_range(0.0, 1.0) = 0;
uniform float roughness : hint_range(0.0, 1.0) = 0;
uniform sampler2D noise;
uniform float noise_intensity : hint_range(0, 1) = 0.2;
uniform vec4 gerstner_wave = vec4(1.0, 1.0, 1.0, 1.0);
uniform float time;

// Distance from the map centre (square, like the play area) where fading starts / ends.
// 从地图中心算起(方形距离,和可玩区域一致)开始变透明 / 完全透明的位置。
uniform float fade_start = 120.0;
uniform float fade_end = 148.0;
// The outer sea is outside the VoxelGI bounds and gets almost no light at night,
// so it glows with its own colour to match the main sea.
// 外圈在 VoxelGI 范围外,夜里几乎没有光照,用自身颜色自发光来和主海面一致。
uniform float far_brightness : hint_range(0.0, 2.0) = 1.0;

varying vec3 world_pos;

vec3 gerstner(float wavelength, float steepness, vec2 dir, vec3 p, inout vec3 tangent, inout vec3 binormal) {
	float k = (2.0 * PI) / wavelength;
	float g = 9.8337;
	float c = sqrt(g / k);
	vec2 d = normalize(dir);
	float f = k * dot(d, p.xz) - c * time;
	float a = steepness / k;
	float wave_noise = texture(noise, p.xz / 100.0 + dir * time * -0.0025).r * noise_intensity - noise_intensity / 2.0;
	tangent += vec3(
		-d.x * d.x * (steepness * sin(f)),
		d.x * (steepness * cos(f)) + wave_noise,
		-d.x * d.y * (steepness * sin(f))
	);
	binormal += vec3(
		-d.x * d.y * (steepness * sin(f)),
		d.y * (steepness * cos(f)) + wave_noise,
		-d.y * d.y * (steepness * sin(f))
	);
	return vec3(d.x * (a * cos(f)), a * sin(f) + wave_noise, d.y * (a * cos(f)));
}

void vertex() {
	vec3 point = VERTEX.xyz;
	vec3 tangent = vec3(1, 0, 0);
	vec3 binormal = vec3(0, 0, 1);
	point += gerstner(gerstner_wave.x, gerstner_wave.y, vec2(gerstner_wave.z, gerstner_wave.w), point, tangent, binormal);
	VERTEX.xyz = point;
	NORMAL = normalize(cross(binormal, tangent));
	world_pos = (MODEL_MATRIX * vec4(point, 1.0)).xyz;
}

void fragment() {
	float height_blend = smoothstep(blend_from, blend_to, world_pos.y);
	ALBEDO = mix(albedo, albedo_high, height_blend);
	EMISSION = ALBEDO * far_brightness;
	METALLIC = metallic;
	ROUGHNESS = roughness;
	RIM = 0.5;
	float edge_dist = max(abs(world_pos.x), abs(world_pos.z));
	ALPHA = 1.0 - smoothstep(fade_start, fade_end, edge_dist);
}

void light() {
	if (LIGHT_IS_AREA) {
		DIFFUSE_LIGHT += LIGHT_AREA_DIFFUSE_MULTIPLIER * ATTENUATION * LIGHT_COLOR;
		SPECULAR_LIGHT += LIGHT_AREA_SPECULAR_MULTIPLIER * ATTENUATION * LIGHT_COLOR * SPECULAR_AMOUNT;
	} else {
		DIFFUSE_LIGHT += clamp(dot(NORMAL, LIGHT), 0.0, 1.0) * ATTENUATION * LIGHT_COLOR / PI;
	}
}
