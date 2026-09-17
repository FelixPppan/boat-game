shader_type spatial;
// render_mode unshaded;

uniform vec3 albedo : source_color;
uniform float metallic : hint_range(0.0, 1.0) = 0;
uniform float roughness : hint_range(0.0, 1.0) = 0;

uniform sampler2D texture_normal;

void vertex() {
	// Called for every vertex the material is visible on.
	VERTEX.y = 0.05 * sin(5.0 * VERTEX.x + 2.0 * TIME) + 0.05 * sin(3.0 * VERTEX.z + 2.0 * TIME);
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