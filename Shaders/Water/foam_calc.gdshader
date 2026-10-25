shader_type canvas_item;
uniform sampler2D displacement_map;

vec3 get_displacement(vec2 uv) {
	// Returns the displacement at the specified position in the displacement map
	vec3 uv_displacement = texture(displacement_map, uv).xyz;
	return uv_displacement;
}

void fragment() {
	// Called for every pixel the material is visible on.
	vec2 fragment_size = 1.0 / vec2(textureSize(displacement_map, 0)); // Size of fragment on displacement map
	vec2 sample_distance = fragment_size * 100.0;
	
	vec2 point = (UV - 0.5) * 100.0;
	vec2 displaced_point = point + get_displacement(UV).xz;
	
	// Getting a sample point along the sample area in each dimension
	vec2 sample_x =  point + vec2(sample_distance.x, 0) + get_displacement(UV + vec2(fragment_size.x, 0)).xz;
	vec2 sample_z =  point + vec2(0, sample_distance.y) + get_displacement(UV + vec2(0, fragment_size.y)).xz;
	
	// Computing the areas
	float initial_area = sample_distance.x * sample_distance.y;
	float compressed_area = cross(vec3(sample_x - displaced_point, 0), vec3(sample_z - displaced_point,0)).z; // Magnitude of cross product = area of parallelogram
	
	// Compares the size of the sample area before with the sample area after displacement
	float jacobian_determinant = compressed_area / initial_area; // How "compressed" the water is
	float compression = 1.0 - smoothstep(0, 0.7, jacobian_determinant); // 0.0 = no compression, 1.0 = maximum compression
	
	COLOR = vec4(vec3(compression), 1);
}