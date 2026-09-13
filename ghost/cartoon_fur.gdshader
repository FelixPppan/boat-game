shader_type spatial;
render_mode diffuse_lambert_wrap;

uniform vec4 fur_color : source_color =
    vec4(0.48, 0.40, 0.34, 1.0);

uniform sampler2D fur_noise : repeat_enable, filter_linear_mipmap;

uniform float texture_scale : hint_range(0.5, 12.0) = 3.0;
uniform float color_variation : hint_range(0.0, 0.5) = 0.12;

void fragment() {
    // 拉长噪声，形成初步的毛纹方向
    vec2 fur_uv = UV * vec2(2.0, 0.7) * texture_scale;
    float noise = texture(fur_noise, fur_uv).r;

    float shade = 1.0 + (noise - 0.5) * 2.0 * color_variation;

    ALBEDO = fur_color.rgb * shade;
    ROUGHNESS = 1.0;
    SPECULAR = 0.15;

    // 少量受灯光影响的边缘亮度
    RIM = 0.2;
    RIM_TINT = 1.0;
}