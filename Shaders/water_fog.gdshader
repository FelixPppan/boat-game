shader_type fog;

uniform float base_density : hint_range(0.0, 5.0) = 0.5;
uniform vec3 fog_color : source_color = vec3(0.714, 0.694, 0.812);
uniform sampler3D noise_texture : repeat_enable;

uniform float fog_height_max = 2.0;
uniform vec3 boat_position = vec3(0.0);
uniform float boat_inner_radius = 1.5;
uniform float boat_outer_radius = 8.0;

void fog() {
    vec3 world_pos = WORLD_POSITION;
    
    // Altitude Decay 高度衰减
    float height_raw = clamp((fog_height_max - world_pos.y) / fog_height_max, 0.0, 1.0);
    float height_factor = height_raw * height_raw;
    if (height_factor <= 0.0) { DENSITY = 0.0; }
    
    // Dynamic 3D Noise 动态 3D 噪声
    vec3 noise_uv = world_pos * 0.25 + vec3(TIME * 0.2, 0.0, TIME * 0.05);
    float noise_val = texture(noise_texture, noise_uv).r;
    
    // Moves smoothly with the boat 随船移动平滑推开
    float boat_dist = length(world_pos.xz - boat_position.xz);
    float boat_mask = smoothstep(boat_inner_radius, boat_outer_radius, boat_dist + (noise_val - 0.5) * 1.5);
    
    DENSITY = pow(base_density * height_factor * boat_mask * noise_val, 1.2);
    ALBEDO = fog_color;
    EMISSION = fog_color * 0.4; // Self-luminous 自发光40%
}