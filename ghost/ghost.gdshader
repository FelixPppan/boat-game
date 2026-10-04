shader_type spatial;
render_mode unshaded;

uniform vec4 ghost_color : source_color =
    vec4(0.72, 0.78, 0.82, 1.0);

// Top and bottom transparency
uniform float top_opacity : hint_range(0.0, 1.0) = 0.85;
uniform float bottom_opacity : hint_range(0.0, 1.0) = 0.05;

// Local-space heights where the fade starts and reaches full opacity.
uniform float bottom_height = -1.0;
uniform float top_height = 1.0;

// The higher the value, the wider the range of contour dissipation.
uniform float edge_softness : hint_range(0.01, 1.0) = 0.5;
// Keep the cloth silhouette visible instead of dissolving it completely.
uniform float edge_opacity : hint_range(0.0, 1.0) = 0.9;
uniform float grain_opacity_strength : hint_range(0.0, 1.0) = 0.03;

// Particle strength and size
uniform float grain_strength : hint_range(0.0, 1.0) = 0.35;
uniform float grain_size : hint_range(1.0, 6.0) = 1.0;
uniform vec4 glow_color : source_color =
    vec4(0.65, 0.85, 1.0, 1.0);

uniform float glow_strength : hint_range(0.0, 5.0) = 0.3;

varying float local_height;

// Generate random grayscale grain.
float random_value(vec2 p) {
    return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void vertex() {
    local_height = VERTEX.y;
}

void fragment() {
    // 1. Transparency gradient from bottom to top
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

    // 2. The surface becomes more transparent the closer it is to the side, creating a soft edge.
    float facing = clamp(
        dot(normalize(NORMAL), normalize(VIEW)),
        0.0,
        1.0
    );

    float soft_edge = mix(edge_opacity, 1.0,
        smoothstep(0.0, edge_softness, facing));

    // 3. Fine-grained screen pixel size
    vec2 grain_position = floor(FRAGCOORD.xy / grain_size);
    float noise = random_value(grain_position);
    float grain = mix(1.0, noise, grain_strength);

    // Color contrast is independent of transparency so grain does not expose the body.
    ALBEDO = ghost_color.rgb * grain;
	EMISSION = glow_color.rgb * glow_strength;
    ALPHA = body_alpha * soft_edge * mix(1.0, noise, grain_opacity_strength);
}
