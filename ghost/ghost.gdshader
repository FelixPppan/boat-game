shader_type spatial;
render_mode unshaded, cull_back;

uniform vec4 ghost_color : source_color =
    vec4(0.72, 0.78, 0.82, 1.0);

// 上下透明度
uniform float top_opacity : hint_range(0.0, 1.0) = 0.85;
uniform float bottom_opacity : hint_range(0.0, 1.0) = 0.05;

// 模型局部坐标中的底部和顶部高度
uniform float bottom_height = -1.0;
uniform float top_height = 1.0;

// 数值越大，轮廓消散范围越宽
uniform float edge_softness : hint_range(0.01, 1.0) = 0.5;

// 颗粒强度与大小
uniform float grain_strength : hint_range(0.0, 1.0) = 0.35;
uniform float grain_size : hint_range(1.0, 6.0) = 1.0;
uniform vec4 glow_color : source_color =
    vec4(0.65, 0.85, 1.0, 1.0);

uniform float glow_strength : hint_range(0.0, 5.0) = 0.3;

varying float local_height;

// 生成随机灰度颗粒
float random_value(vec2 p) {
    return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void vertex() {
    local_height = VERTEX.y;
}

void fragment() {
    // 1. 从底部到顶部的透明度渐变
    float height_factor = smoothstep(
        bottom_height,
        top_height,
        local_height
    );

    float body_alpha = mix(
        bottom_opacity,
        top_opacity,
        height_factor
    );

    // 2. 越靠近侧面的表面越透明，形成柔边
    float facing = clamp(
        dot(normalize(NORMAL), normalize(VIEW)),
        0.0,
        1.0
    );

    float soft_edge = smoothstep(0.0, edge_softness, facing);

    // 3. 屏幕像素大小的细颗粒
    vec2 grain_position = floor(FRAGCOORD.xy / grain_size);
    float noise = random_value(grain_position);
    float grain = mix(1.0, noise, grain_strength);

    ALBEDO = ghost_color.rgb * mix(0.85, 1.0, noise);
	EMISSION = glow_color.rgb * glow_strength;
    ALPHA = body_alpha * soft_edge * grain;
}