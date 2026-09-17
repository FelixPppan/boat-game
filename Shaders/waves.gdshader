shader_type spatial;
// render_mode unshaded;

uniform vec3 albedo : source_color;
uniform float metallic : hint_range(0.0, 1.0) = 0;
uniform float roughness : hint_range(0.0, 1.0) = 0;

uniform float speed = 2.0; // Speed
uniform float ampl = 0.05; // Amplitude
uniform float ang = 3.0; // Angular frequency

uniform sampler2D texture_normal;

/*
Sources used:
https://developer.nvidia.com/gpugems/gpugems/part-i-natural-effects/chapter-1-effective-water-simulation-physical-models
https://catlikecoding.com/unity/tutorials/flow/waves/
https://en.wikipedia.org/wiki/Trochoidal_wave
*/

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
	
	float f = k * dot(d, p.xz) - c * TIME; // Function inside sin/cos wave	
	float a = steepness / k;
	
	tangent += vec3(
		-d.x * d.x * (steepness * sin(f)),
		d.x * (steepness * cos(f)),
		-d.x * d.y * (steepness * sin(f))
		);
		
	binormal += vec3(
		-d.x * d.y * (steepness * sin(f)),
		d.y * (steepness * cos(f)),
		-d.y * d.y * (steepness * sin(f))
	);
	
	return vec3(d.x * (a * cos(f)), a * sin(f), d.y * (a * cos(f)));
}

void vertex() {
	// Called for every vertex the material is visible on.
	vec3 point = VERTEX.xyz;
	vec3 tangent = vec3(1,0,0);
	vec3 binormal = vec3(0,0,1);
	
	vec3 p = point;
	
	p += gerstner(1, 0.1, vec2(1, 0), p, tangent, binormal);
	p += gerstner(0.5, 0.1, vec2(0, 1), p, tangent, binormal);
	p += gerstner(0.5, 0.1, vec2(0.5, 0.5), p, tangent, binormal);
	
	vec3 normal = normalize(cross(binormal, tangent));
	
	VERTEX.xyz = p;
	NORMAL = normal;
}

void fragment() {
	// Called for every pixel the material is visible on.	
	ALBEDO = albedo;
	METALLIC = metallic;
	ROUGHNESS = roughness;
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