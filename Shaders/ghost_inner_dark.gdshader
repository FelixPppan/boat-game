shader_type spatial;
render_mode unshaded;

// Solid dark body: no lighting, specular highlights, or transparency.
// Scene fog and post-processing can still affect its final appearance.
uniform vec4 body_color : source_color = vec4(0.025, 0.03, 0.04, 1.0);
uniform vec4 glow_color : source_color = vec4(0.45, 0.65, 1.0, 1.0);
uniform float glow_strength : hint_range(0.0, 5.0, 0.01) = 0.08;

void fragment() {
    ALBEDO = body_color.rgb;
    EMISSION = glow_color.rgb * glow_strength;
}
