/*
TODO:
	- Implement foam using Jacobian
	- Implement sub-surface scattering
	- Get buoyancy working properly

Sources used:
	https://developer.nvidia.com/gpugems/gpugems/part-i-natural-effects/chapter-1-effective-water-simulation-physical-models
	https://catlikecoding.com/unity/tutorials/flow/waves/
	https://en.wikipedia.org/wiki/Trochoidal_wave
*/

shader_type spatial;
render_mode blend_mix, depth_draw_opaque;
stencil_mode read, compare_not_equal, 1;

// Colour and texture
uniform vec3 albedo : source_color;
uniform vec3 albedo_high : source_color;
uniform float blend_from : hint_range(-1.0, 0.0) = -0.1;
uniform float blend_to : hint_range(0.0, 1.0) = 0.1;
uniform float metallic : hint_range(0.0, 1.0) = 0;
uniform float roughness : hint_range(0.0, 1.0) = 0;

// Noise map
uniform sampler2D noise;
uniform float noise_intensity: hint_range(0,1) = 0.2;

// Gerstner settings
uniform vec4 gerstner_wave = vec4(1.0, 1.0, 1.0, 1.0);

uniform float size_of_plane = 100.0;

// For use by water.gd script when synching buoyancy physics
uniform float time; // Change to TIME to unbind from script

// --- Aurora mist trail (sparse large-scale filaments) -------------------
uniform sampler2D trail_mask : hint_default_black, filter_linear, repeat_disable;
uniform vec2 trail_world_center = vec2(0.0);
uniform float trail_world_size = 100.0;
uniform sampler2D trail_gradient : source_color, filter_linear, repeat_disable;
/// Hue stops on gradient for layers A/B/C (cyan / mint / lilac).
uniform vec3 trail_layer_u = vec3(0.22, 0.48, 0.88);
uniform float trail_strength : hint_range(0.0, 5.0) = 2.2;
uniform float trail_softness : hint_range(0.05, 4.0) = 2.0;
/// Overall filament density/brightness after threshold.
uniform float trail_flow : hint_range(0.0, 1.5) = 1.0;
/// Main noise UV scale — smaller = thicker, longer strands (avoid >0.08).
uniform float trail_flow_scale : hint_range(0.008, 0.12) = 0.028;
/// Low-frequency domain-warp strength (metres-ish via noise).
uniform float trail_warp : hint_range(0.0, 8.0) = 3.5;
/// smoothstep low/high — raise edge_min for more dark gaps.
uniform float trail_edge_min : hint_range(0.0, 0.9) = 0.52;
uniform float trail_edge_max : hint_range(0.1, 1.0) = 0.78;
/// Soft halo around cores (0 = hard ribbons only).
uniform float trail_halo : hint_range(0.0, 1.0) = 0.45;
uniform float trail_core_boost : hint_range(0.5, 3.0) = 1.75;

/// Displaced world XZ for trail sampling (set after Gerstner).
varying vec2 trail_xz;

float sample_trail(vec2 world_xz) {
	vec2 uv = (world_xz - trail_world_center) / max(trail_world_size, 0.001) + vec2(0.5);
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
		return 0.0;
	}
	return texture(trail_mask, uv).r;
}

float sample_trail_soft(vec2 world_xz) {
	// Slight spatial blur so Gerstner stretch doesn't tear thin mask strips.
	float r = max(trail_softness * 0.35, 0.08);
	float n1 = texture(noise, world_xz * 0.018).r - 0.5;
	float n2 = texture(noise, world_xz * 0.022 + vec2(1.3, 2.1)).r - 0.5;
	vec2 warp = vec2(n1, n2) * r;
	float c = sample_trail(world_xz);
	float a = sample_trail(world_xz + warp);
	float b = sample_trail(world_xz - warp * 0.7);
	float d = sample_trail(world_xz + vec2(warp.y, -warp.x) * 0.6);
	return max(c, max(a, max(b, d)) * 0.92);
}

/// Soft ribbon from noise: threshold for dark gaps + soft body + bright core.
float filament_from_noise(float n) {
	float body = smoothstep(trail_edge_min, trail_edge_max, n);
	float core = smoothstep(
		mix(trail_edge_min, trail_edge_max, 0.55),
		trail_edge_max,
		n
	);
	float halo = smoothstep(trail_edge_min * 0.65, trail_edge_min, n) * trail_halo;
	return clamp(halo * 0.35 + body * 0.75 + core * trail_core_boost, 0.0, 2.5);
}

/// Large-scale domain-warped smoke ribbons (sparse, curving).
vec3 smoke_layers(vec2 world_xz) {
	float t = time * 0.018;
	vec2 w = world_xz;

	// Very low-frequency warp → big aurora curls (fig.2).
	float warp_s = 0.012;
	vec2 warp;
	warp.x = texture(noise, w * warp_s + vec2(t * 0.35, 0.0)).r - 0.5;
	warp.y = texture(noise, w * warp_s + vec2(0.0, -t * 0.28) + vec2(3.1, 1.7)).r - 0.5;
	w += warp * trail_warp;

	// Second milder warp for braided look.
	vec2 warp2;
	warp2.x = texture(noise, w * 0.02 + vec2(-t * 0.2, 2.4)).r - 0.5;
	warp2.y = texture(noise, w * 0.02 + vec2(4.8, t * 0.22)).r - 0.5;
	w += warp2 * (trail_warp * 0.35);

	float s = trail_flow_scale;
	float n1 = texture(noise, w * s + vec2(t * 0.45, 0.0)).r;
	float n2 = texture(noise, w * (s * 1.35) + vec2(-t * 0.55, 5.2)).r;
	float n3 = texture(noise, w * (s * 0.72) + vec2(2.8, t * 0.38)).r;

	float r1 = filament_from_noise(n1);
	float r2 = filament_from_noise(n2);
	float r3 = filament_from_noise(n3);

	return clamp(vec3(r1, r2, r3) * trail_flow, 0.0, 2.5);
}

vec3 filament_colour(float intensity, float u_stop) {
	vec4 g = texture(trail_gradient, vec2(clamp(u_stop, 0.0, 1.0), 0.0));
	vec3 hue = g.rgb;
	float peak = max(hue.r, max(hue.g, hue.b));
	if (peak > 1e-4) {
		hue = hue / peak;
		// Hot core leans toward white; soft body keeps hue.
		float hot = smoothstep(0.55, 1.4, intensity);
		hue = mix(hue * 0.85, vec3(1.0), hot * 0.35);
	}
	float w = smoothstep(0.02, 0.55, clamp(intensity, 0.0, 2.5));
	return hue * w * intensity * max(g.a, 0.001);
}

vec3 combine_aurora(vec3 a, vec3 b, vec3 c) {
	vec3 m = max(a, max(b, c));
	return m + (a + b + c - m) * 0.28;
}

// Function for creating Gerstner waves
vec3 gerstner(
	float wavelength, 
	float steepness, 
	vec2 dir, 
	vec3 p,
	inout vec3 tangent, 
	inout vec3 binormal) {
	
	float k = (2.0 * PI) / wavelength; // Wave number 
	float g = 9.8337; // Gravity constant
	float c = sqrt(g/k); // Phase speed
	
	vec2 d = normalize(dir); // Direction
	
	float f = k * dot(d, p.xz) - c * time; // Function inside sin/cos wave	
	float a = steepness / k;
	
	float wave_noise = texture(noise, p.xz / size_of_plane + dir * time * -0.0025).r * noise_intensity - noise_intensity / 2.0;
	
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
	
	float x = d.x * (a * cos(f));
	float y = a * sin(f) + wave_noise;
	float z = d.y * (a * cos(f));
	
	return vec3(x, y, z);
}

void create_wave(inout vec3 p, inout vec3 tangent, inout vec3 binormal) {
	p += gerstner(gerstner_wave.x, gerstner_wave.y, vec2(gerstner_wave.z, gerstner_wave.w), p, tangent, binormal);
}

void vertex() {
	vec3 point = VERTEX.xyz;
	vec3 tangent = vec3(1, 0, 0);
	vec3 binormal = vec3(0, 0, 1);
	create_wave(point, tangent, binormal);

	vec3 normal = normalize(cross(binormal, tangent));
	VERTEX.xyz = point;
	NORMAL = normal;
	// History mask is painted in world XZ — sample the surface's current world XZ
	// (after Gerstner), not rest-pose, or troughs sample empty mask cells.
	trail_xz = (MODEL_MATRIX * vec4(point, 1.0)).xz;
}

void fragment() {
	vec4 world_position = INV_VIEW_MATRIX * vec4(VERTEX, 1);
	float height_blend = smoothstep(blend_from, blend_to, world_position.y);
	vec3 albedo_mix = mix(albedo, albedo_high, height_blend);

	ALBEDO = albedo_mix;
	METALLIC = metallic;
	ROUGHNESS = roughness;
	RIM = 0.5;
	ALPHA = 1.0;

	// Continuous trail: mask intensity only — never gated by wave height.
	float trail_m = sample_trail_soft(trail_xz);
	EMISSION = vec3(0.0);
	if (trail_m > 0.002) {
		float fade = smoothstep(0.0, 0.14, trail_m);
		vec3 layers = smoke_layers(trail_xz);
		layers *= mix(0.5, 1.0, fade);
		vec3 a = filament_colour(layers.x * trail_m, trail_layer_u.x);
		vec3 b = filament_colour(layers.y * trail_m, trail_layer_u.y);
		vec3 c = filament_colour(layers.z * trail_m, trail_layer_u.z);
		// Strong base mist so troughs stay lit even where filaments are sparse.
		vec3 mist = filament_colour(trail_m * 0.55, trail_layer_u.y) * 0.55;
		vec3 aurora = combine_aurora(a, b, c) + mist;
		float peak = max(aurora.r, max(aurora.g, aurora.b));
		aurora *= 1.0 / (1.0 + peak * 0.3);
		EMISSION = aurora * fade * trail_strength;
	}
}

void light() {
    if (LIGHT_IS_AREA) {
        // Area light GGX shading.
        DIFFUSE_LIGHT += LIGHT_AREA_DIFFUSE_MULTIPLIER * ATTENUATION * LIGHT_COLOR;
        SPECULAR_LIGHT += LIGHT_AREA_SPECULAR_MULTIPLIER * ATTENUATION * LIGHT_COLOR * SPECULAR_AMOUNT;
    } else {
        // Used for all other light types (directional, omni, spot).
        DIFFUSE_LIGHT += clamp(dot(NORMAL, LIGHT), 0.0, 1.0) * ATTENUATION * LIGHT_COLOR / PI;
    }
}