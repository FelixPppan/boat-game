shader_type canvas_item;

// Noise map
uniform sampler2D noise: repeat_enable;
uniform float noise_intensity: hint_range(0,1) = 0.2;

// Gerstner settings
uniform vec4 gerstner_wave = vec4(1.0, 1.0, 1.0, 1.0);

// For use by water.gd script when synching buoyancy physics
uniform float time; // Change to TIME to unbind from script

uniform float size_of_plane = 10.0;

// Function for creating Gerstner waves
vec3 gerstner(
	float wavelength, 
	float steepness, 
	vec2 dir, 
	vec2 point,
	bool noise_on) {
	
	float k = (2.0 * PI) / wavelength; // Wave number 
	float g = 9.8337; // Gravity constant
	float c = sqrt(g/k); // Phase speed
	
	vec2 d = normalize(dir); // Direction
	
	float f = k * dot(d, point) - c * time; // Function inside sin/cos wave	
	float a = steepness / k;
	
	float wave_noise = 0.0;
	if (noise_on) {
		wave_noise = texture(noise, point / size_of_plane + dir * time * -0.0025).r * noise_intensity - noise_intensity / 2.0;
	}
		
	float x = d.x * (a * cos(f));
	float y = a * sin(f) + wave_noise;
	float z = d.y * (a * cos(f));
	
	return vec3(x, y, z);
}

vec3 create_wave(vec2 point) {
	vec3 displacement = gerstner(gerstner_wave.x, gerstner_wave.y, vec2(gerstner_wave.z, gerstner_wave.w), point, true);
	displacement += gerstner(gerstner_wave.x * 0.8, gerstner_wave.y * 0.5, vec2(gerstner_wave.z * 0.5, gerstner_wave.w *1.5), point, false);
	displacement += gerstner(gerstner_wave.x * 0.5, gerstner_wave.y * 1.5, vec2(gerstner_wave.z * 0.5, gerstner_wave.w *1.5), point, false);
	// displacement += gerstner(gerstner_wave.x * 0.4, gerstner_wave.y * 1.5, vec2(gerstner_wave.z * 0.5, gerstner_wave.w *1.5), point);
	
	return displacement;
}

void fragment() {
	// Called for every pixel the material is visible on.
	vec2 point = (UV - 0.5) * size_of_plane; // Middle of UV mesh is 0.5
	vec3 displacement = create_wave(point);
	
	COLOR = vec4(displacement, 1.0);
}

//void light() {
//	// Called for every pixel for every light affecting the CanvasItem.
//	// Uncomment to replace the default light processing function with this one.
//}
