@tool
extends Control
## Arrowheads for a plain GraphEdit (the flat graph): GraphEdit draws
## bare lines, Unreal draws arrows. This overlay reads the graph's
## connection list each frame and puts a UE-style arrowhead where every
## connection lands. Read-only decoration — mouse_filter IGNORE.

const UEStyle := preload("res://addons/frameforge/editor/ue_style.gd")

var graph: GraphEdit = null


func _init() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE


func _process(_delta: float) -> void:
	if graph != null and is_visible_in_tree():
		position = Vector2.ZERO
		size = graph.size
		queue_redraw()


func _draw() -> void:
	if graph == null:
		return
	var inv := get_global_transform().affine_inverse()
	for conn in graph.get_connection_list():
		var from_node := graph.get_node_or_null(
				NodePath(conn["from_node"])) as GraphNode
		var to_node := graph.get_node_or_null(
				NodePath(conn["to_node"])) as GraphNode
		if from_node == null or to_node == null:
			continue
		var a := inv * (from_node.get_global_transform()
				* from_node.get_output_port_position(
						_ordinal(from_node, int(conn["from_port"]), true)))
		var b := inv * (to_node.get_global_transform()
				* to_node.get_input_port_position(
						_ordinal(to_node, int(conn["to_port"]), false)))
		if a.distance_to(b) < 30.0:
			continue
		# Connections always land horizontally (engine control points
		# are horizontal offsets), so the head is a fixed triangle.
		draw_colored_polygon(PackedVector2Array([
			b + Vector2(2, 0), b + Vector2(-10, -5), b + Vector2(-10, 5)]),
				UEStyle.LINE)


## connect_node records SLOT indices; port positions take ORDINALS
## among enabled ports on that side. Convert by counting.
func _ordinal(node: GraphNode, slot: int, right: bool) -> int:
	var ord := 0
	for i in mini(slot, node.get_child_count()):
		if right and node.is_slot_enabled_right(i):
			ord += 1
		elif not right and node.is_slot_enabled_left(i):
			ord += 1
	return ord
