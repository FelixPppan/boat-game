shader_type fog;

uniform float max_density : hint_range(0.0, 15.0) = 8.0; // 初始格外浓厚
uniform vec3 fog_color : source_color = vec3(1.0,1.0,1.0); 
uniform float emission_amount : hint_range(0.0, 1.0) = 0.5;
uniform sampler3D noise_texture : repeat_enable;

// 核心消融控制：1.0 为浓雾覆盖，0.0 为完全轻柔蒸发消失
uniform float dissolve_factor : hint_range(0.0, 1.0) = 1.0;

void fog() {
    vec3 world_pos = WORLD_POSITION;
    
    // 3D Slowly Drifting Fog Noise 3D缓慢飘动的云雾噪声
    vec3 noise_uv = world_pos * 0.3 + vec3(TIME * 0.04, TIME * 0.02, 0.0);
    float noise_val = texture(noise_texture, noise_uv).r;
    
    // 轻柔消融算法：当 dissolve_factor 降低时，配合噪声让密度极其自然地退去
    float current_density = max_density * smoothstep(1.0 - dissolve_factor, 1.0, noise_val) * dissolve_factor;
    
    DENSITY = current_density;
    ALBEDO = fog_color;
    EMISSION = fog_color * 0.8;
}