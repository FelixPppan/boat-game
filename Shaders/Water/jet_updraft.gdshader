shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, shadows_disabled;

void fragment() {
	// Sparse curved streaks keep the column readable without a dense transparent shell.
	float lane = fract(UV.x * 6.0 + UV.y * 0.65);
	float streak = smoothstep(0.04, 0.10, lane) * (1.0 - smoothstep(0.16, 0.23, lane));
	// Cylinder UVs start at the top, so increasing the phase moves the dashes upward.
	float phase = fract(UV.y * 2.0 + TIME * 0.9 + floor(UV.x * 6.0) * 0.37);
	float dash = smoothstep(0.0, 0.12, phase) * (1.0 - smoothstep(0.45, 0.75, phase));
	float edge_fade = smoothstep(0.0, 0.12, UV.y) * (1.0 - smoothstep(0.85, 1.0, UV.y));
	ALBEDO = vec3(0.75, 0.94, 1.0);
	ALPHA = streak * dash * edge_fade * 0.55;
}
