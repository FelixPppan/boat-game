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

// For use by water.gd script when synching buoyancy physics
uniform float time; // Change to TIME to unbind from script

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
	
	float x = d.x * (a * cos(f));
	float y = a * sin(f) + wave_noise;
	float z = d.y * (a * cos(f));
	
	return vec3(x, y, z);
}

void create_wave(inout vec3 p, inout vec3 tangent, inout vec3 binormal) {
	p += gerstner(gerstner_wave.x, gerstner_wave.y, vec2(gerstner_wave.z, gerstner_wave.w), p, tangent, binormal);
}

void vertex() {
	// Called for every vertex the material is visible on.
	vec3 point = VERTEX.xyz;
	vec3 tangent = vec3(1,0,0);
	vec3 binormal = vec3(0,0,1);
	
	create_wave(point, tangent, binormal);
	
	vec3 normal = normalize(cross(binormal, tangent));
	
	VERTEX.xyz = point;
	NORMAL = normal;
}

void fragment() {
	// Called for every pixel the material is visible on.	
	vec4 world_position = INV_VIEW_MATRIX * vec4(VERTEX, 1);
	float height_blend = smoothstep(blend_from, blend_to, world_position.y);
	vec3 albedo_mix = mix(albedo, albedo_high, height_blend);
	
	ALBEDO = albedo_mix;
	METALLIC = metallic;
	ROUGHNESS = roughness;
	RIM = 3.0;
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