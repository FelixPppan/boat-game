shader_type canvas_item;
/// Recolors black silhouette icons: keeps texture alpha, replaces RGB with tint.
uniform vec4 tint : source_color = vec4(1.0);

void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	COLOR = vec4(tint.rgb, tex.a * tint.a);
}
