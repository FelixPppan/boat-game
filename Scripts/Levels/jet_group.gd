@tool
extends Node3D
## Parent of a set of water jets. Setting jet_height here copies it onto every
## child jet at once; each jet can still be given its own height afterwards.
## 一组水柱的父节点。在这里设 jet_height 会一次性复制给所有子水柱;
## 之后仍然可以单独给某根水柱设不同的高度。

@export_range(0.5, 50.0, 0.1) var jet_height: float = 7.0:
	set(value):
		jet_height = value
		if not is_inside_tree():
			return
		for child in get_children():
			if "jet_height" in child:
				child.jet_height = value
