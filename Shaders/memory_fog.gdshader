shader_type fog;

/// Overall thickness. Keep low (0.6–2.0) for soft haze; high values read as
/// solid cotton and amplify volumetric flicker.
uniform float max_density : hint_range(0.0, 5.0) = 1.2;
uniform vec3 fog_color : source_color = vec3(0.95, 0.93, 1.0);
/// Soft self-light. Coupled to density below — do not crank this alone.
uniform float emission_amount : hint_range(0.0, 3.0) = 0.75;
/// How fuzzy the FogVolume boundary is (higher = softer, more ethereal).
uniform float soft_edge : hint_range(0.15, 0.95) = 0.62;
/// World-space noise scale. Smaller = larger, softer billows (less sparkle).
uniform float noise_scale : hint_range(0.02, 0.5) = 0.1;
/// 0 = almost even haze, 1 = stronger holes. Lower = less "solid cloud".
uniform float noise_contrast : hint_range(0.0, 1.0) = 0.45;
/// Lifts dark noise pockets toward fog_color so gaps are milky, not scene-grey.
uniform float shadow_lift : hint_range(0.0, 1.0) = 0.55;
uniform sampler3D noise_texture : repeat_enable;

// 1.0 = full cover, 0.0 = dissolved
uniform float dissolve_factor : hint_range(0.0, 1.0) = 1.0;

void fog() {
	vec3 world_pos = WORLD_POSITION;

	// Soft ellipsoid falloff inside the FogVolume (UVW is 0..1 across the volume).
	// Hard volume edges + temporal reprojection = flicker when the camera bobs.
	float radial = length(UVW - vec3(0.5));
	float edge = 1.0 - smoothstep(soft_edge * 0.45, 0.52, radial);

	// Large, slow noise — soft mist, not crawling speckles.
	vec3 noise_uv = world_pos * noise_scale
			+ vec3(TIME * 0.012, TIME * 0.008, TIME * 0.006);
	float n = texture(noise_texture, noise_uv).r;

	// Soft remap: avoid harsh 0/1 blobs that shimmer under temporal fog.
	float soft_n = smoothstep(0.15, 0.9, n);
	soft_n = mix(0.75, soft_n, noise_contrast);

	float dissolve = smoothstep(1.0 - max(dissolve_factor, 0.001), 1.0, n)
			* dissolve_factor;

	float density = max_density * soft_n * edge * dissolve;
	// Slightly sub-linear so mid-density fills more evenly (less chalky).
	density = pow(max(density, 0.0), 0.8);

	DENSITY = density;

	// Dark pockets lean toward fog_color instead of picking up grey scene light.
	vec3 lifted = mix(fog_color * shadow_lift, fog_color, soft_n);
	ALBEDO = lifted;

	// Emission follows the soft mask — bright cores glow gently, edges stay airy.
	// This avoids "blow out whites / grey holes" from a flat emission_amount.
	float emit_mask = mix(shadow_lift * 0.35, 1.0, soft_n) * edge;
	EMISSION = fog_color * emission_amount * emit_mask;
}
