@tool
extends Control
## Unreal-style transition layer for the grouped detail graph. Every
## drawn transition gets the UE treatment: an arrowhead where the line
## lands, and a circular ⇄ badge riding its midpoint — in Unreal the
## badge marks "a rule lives here" and the rule is revealed on
## interaction. Same here: hovering a badge shows its condition
## (StateGraphNode._cond_summary vocabulary — the flat graph's per-row
## text), clicking selects it (orange line + ring, full condition in
## the grouped view's side panel), and double-click dives to the source
## state in the flat graph. An ENTRY tag straddles the group entry
## state's top edge, where Unreal puts its Entry node + arrow.
##
## Drawn as an overlay child of the GraphEdit (raised above the nodes);
## mouse_filter PASS so only badge clicks are consumed — node drags,
## panning and the graph toolbar pass straight through.

const UEStyle := preload("res://addons/frameforge/editor/ue_style.gd")
const StateGraphNode := preload("res://addons/frameforge/editor/state_graph_node.gd")

var graph: GraphEdit = null  # the GroupDetailGraph (duck-typed)
var _hits: Array = []  # {pos, state, index, row, target}
var _hover: Dictionary = {}


func _init() -> void:
	mouse_filter = MOUSE_FILTER_PASS


func _process(_delta: float) -> void:
	if graph != null and is_visible_in_tree():
		# GraphEdit manages its children's rects; re-assert the
		# full-graph rect every frame so size-based label placement
		# and hit areas stay in graph space.
		position = Vector2.ZERO
		size = graph.size
		queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var hit := _pick(event.position)
		if hit != _hover:
			_hover = hit
	elif event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		var hit := _pick(event.position)
		if not hit.is_empty() and graph != null:
			if event.double_click:
				graph.badge_double_clicked(hit)
			else:
				graph.badge_clicked(hit)
			accept_event()


func _pick(pos: Vector2) -> Dictionary:
	var best := {}
	var best_d := 15.0
	for h in _hits:
		var d: float = pos.distance_to(h["pos"])
		if d < best_d:
			best_d = d
			best = h
	return best


func _draw() -> void:
	_hits.clear()
	if graph == null:
		return
	var drawn: Dictionary = graph.get_drawn()
	var nodes: Dictionary = graph.get_nodes()
	if drawn.is_empty():
		return
	var font := get_theme_default_font()
	var inv := get_global_transform().affine_inverse()
	var sel: Dictionary = graph.get_selected_edge()
	# Pass 1: geometry for every drawn edge; arrowheads for all, the
	# orange overlay line for the selected one.
	var geoms: Array = []
	for s in drawn:
		if not nodes.has(s):
			continue
		var from_node: GraphNode = nodes[s]
		var edges: Array = drawn[s]
		for j in edges.size():
			var target: FrameState = edges[j]["target"]
			if target == s or not nodes.has(target):
				continue  # self-loops are the row glyph, not a line
			var to_node: GraphNode = nodes[target]
			var a := inv * (from_node.get_global_transform()
					* from_node.get_output_port_position(j))
			var b := inv * (to_node.get_global_transform()
					* to_node.get_input_port_position(0))
			# Engine bend, in graph units, applied to canvas points.
			var bend := clampf(absf(b.x - a.x) * 0.5,
					40.0 * graph.zoom, 240.0 * graph.zoom)
			var c1 := a + Vector2(bend, 0)
			var c2 := b - Vector2(bend, 0)
			var is_sel: bool = not sel.is_empty() and sel["state"] == s \
					and int(sel["index"]) == j
			geoms.append({"a": a, "b": b, "c1": c1, "c2": c2,
					"mid": _cubic(a, c1, c2, b, 0.5), "state": s,
					"index": j, "row": edges[j]["row"], "target": target,
					"sel": is_sel})
			if a.distance_to(b) > 30.0:
				_draw_arrowhead(b, UEStyle.LINE)
			if is_sel:
				var pts := PackedVector2Array()
				for k in 17:
					pts.append(_cubic(a, c1, c2, b, k / 16.0))
				draw_polyline(pts, UEStyle.SELECT, 3.0, true)
	# Pass 2: badges, interaction labels, hit records.
	for g in geoms:
		var mid: Vector2 = g["mid"]
		var ring: Color = UEStyle.SELECT if g["sel"] else UEStyle.LINE
		draw_circle(mid, 9.0, UEStyle.BADGE_FILL)
		draw_arc(mid, 9.0, 0, TAU, 24, ring, 1.7, true)
		_draw_glyph(mid, ring)
		var hit := {"pos": mid, "state": g["state"], "index": g["index"],
				"row": g["row"], "target": g["target"]}
		_hits.append(hit)
		if g["sel"] or hit == _hover:
			var row: FFTransition = g["row"]
			var cond: FFCondition = row.condition if row != null else null
			_draw_label(mid, StateGraphNode._cond_summary(cond), font)
	_draw_entry_tag(font, inv, nodes)


## The line always lands horizontally (engine control points are
## horizontal offsets), so the arrowhead is a fixed triangle at the
## target port.
func _draw_arrowhead(b: Vector2, col: Color) -> void:
	draw_colored_polygon(PackedVector2Array([
		b + Vector2(2, 0), b + Vector2(-10, -5), b + Vector2(-10, 5)]), col)


func _draw_entry_tag(font: Font, inv: Transform2D, nodes: Dictionary) -> void:
	var entry: FrameState = graph.get_entry_state()
	if entry == null or not nodes.has(entry):
		return
	var node: GraphNode = nodes[entry]
	var tl := inv * (node.get_global_transform() * Vector2.ZERO)
	var tag := "ENTRY"
	var tw := font.get_string_size(tag, HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x
	var rect := Rect2(tl + Vector2(10, -9), Vector2(tw + 14, 18))
	UEStyle.pill(UEStyle.BADGE_FILL, UEStyle.SELECT).draw(get_canvas_item(), rect)
	draw_string(font, rect.position + Vector2(7, 13.5), tag,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10, UEStyle.INK)
	var cx := rect.get_center().x
	draw_colored_polygon(PackedVector2Array([
		Vector2(cx - 4, rect.end.y), Vector2(cx + 4, rect.end.y),
		Vector2(cx, rect.end.y + 5)]), UEStyle.SELECT)


func _draw_label(mid: Vector2, text: String, font: Font) -> void:
	var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
	var max_x := graph.size.x if graph != null else size.x
	var tpos := mid + Vector2(13.0, 4.0)
	if tpos.x + tw > max_x - 4.0:
		tpos = mid + Vector2(-13.0 - tw, 4.0)
	# Never clip the start of the condition off the graph's edge.
	tpos.x = clampf(tpos.x, 4.0, maxf(4.0, max_x - tw - 4.0))
	draw_rect(Rect2(tpos + Vector2(-3, -11), Vector2(tw + 6, 16)),
			Color(0.07, 0.07, 0.09, 0.92))
	draw_string(font, tpos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
			UEStyle.INK)


## Two opposing arrows — the Unreal transition glyph.
func _draw_glyph(c: Vector2, col: Color) -> void:
	draw_line(c + Vector2(-4.5, -2.6), c + Vector2(3.2, -2.6), col, 1.4, true)
	draw_colored_polygon(PackedVector2Array([
		c + Vector2(5.0, -2.6), c + Vector2(1.8, -4.7), c + Vector2(1.8, -0.5)]), col)
	draw_line(c + Vector2(4.5, 2.6), c + Vector2(-3.2, 2.6), col, 1.4, true)
	draw_colored_polygon(PackedVector2Array([
		c + Vector2(-5.0, 2.6), c + Vector2(-1.8, 0.5), c + Vector2(-1.8, 4.7)]), col)


func _cubic(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2,
		t: float) -> Vector2:
	var u := 1.0 - t
	return u * u * u * p0 + 3.0 * u * u * t * p1 \
			+ 3.0 * u * t * t * p2 + t * t * t * p3
