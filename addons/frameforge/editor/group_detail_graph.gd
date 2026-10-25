@tool
extends GraphEdit
## Grouped view, detail level: the states of one superstate as compact
## nodes in BFS layers from the group entry. Only local (non-shared)
## in-group transitions are drawn as edges; shared-rule rows collapse into
## the ⇢/R× badges on the node meta line, and cross-group traffic lives on
## the border-port chips beside this graph. Double-click a node to open it
## in the flat graph for row editing.

signal dive_requested(state: FrameState)
signal edge_selected(state: FrameState, row: FFTransition, target: FrameState)

const GroupModel := preload("res://addons/frameforge/editor/group_model.gd")
const SelfLoopGlyph := preload("res://addons/frameforge/editor/self_loop_glyph.gd")
const EdgeBadgeLayer := preload("res://addons/frameforge/editor/edge_badge_layer.gd")
const UEStyle := preload("res://addons/frameforge/editor/ue_style.gd")

## Every edge drawn here is a local transition (shared rules live in the
## badges, not lines), so ports and lines share one flat local-flow
## color — no gradient, nothing to decode. Gold/dashed is reserved for
## shared rules on the map. The color is bright and the lines thick
## (see _init): at fit-zoom a 1px line averages into the black
## background in any downscaled view and reads as a blue-to-black
## gradient that isn't in the data.
const COL_EDGE := Color(0.72, 0.75, 0.80)


func _init() -> void:
	connection_lines_thickness = 3.5
	UEStyle.apply_graph_canvas(self)


## Golden ratio, used for the layout proportions below.
const PHI := 1.618034

const NODE_W := 210.0
const COL_DX := 268.0
## Vertical gap between stacked nodes, chosen so the gaps follow the
## golden ratio: horizontal clearance (COL_DX - NODE_W = 58) : ROW_DY
## = PHI : 1. 58 / PHI = 35.85 — which also clears the ENTRY tag's 9px
## overhang above a node, with room to spare.
const ROW_DY := (COL_DX - NODE_W) / PHI
const MAX_COL := 8

var _machine: SubStateMachine = null
var _editor: Control = null
var _group := ""
var _analysis: Dictionary = {}
var _nodes := {}  # FrameState -> GraphNode
var _meta := {}  # FrameState -> Label
var _last_pick_state: FrameState = null
var _last_pick_msec := 0
var _refresh_pending := false
var _settle_frames := 0
var _content_size := Vector2.ZERO
var _drawn := {}
var _layer: Control = null
var _selected_edge := {}


func setup(machine: SubStateMachine, editor: Control, group: String,
		analysis: Dictionary) -> void:
	_machine = machine
	_editor = editor
	_group = group
	_analysis = analysis
	if not node_selected.is_connected(_on_node_selected):
		node_selected.connect(_on_node_selected)
	refresh()
	# GraphEdit derives a bogus scroll offset (one viewport up, into
	# negative space) from the layout churn of the main-screen switch,
	# and applies it after any one-shot reset. Pin the camera to the
	# group entry for the first frames after each (re)build instead;
	# a late manual set sticks, so this always wins. After the window,
	# pan/zoom belong to the user.
	_settle_frames = 90
	set_process(true)


func _process(_delta: float) -> void:
	if _settle_frames > 0:
		_settle_frames -= 1
		if size.x > 10.0 and _content_size.x > 0.0:
			zoom = clampf(minf(size.x / _content_size.x,
					size.y / _content_size.y), 0.15, 1.0)
			scroll_offset = Vector2.ZERO
		if _settle_frames == 0:
			set_process(false)


func _on_first_size() -> void:
	_refresh_pending = false
	refresh()


func refresh() -> void:
	# Building while this GraphEdit still has no real size (it is created
	# during the main-screen switch) makes GraphEdit clamp its scroll
	# against an empty rect and bury the content a page down. Wait for the
	# first real resize instead.
	if (size.x < 10.0 or size.y < 10.0) and _machine != null:
		if not _refresh_pending:
			_refresh_pending = true
			resized.connect(_on_first_size, CONNECT_ONE_SHOT)
		return
	for c in get_children():
		if c is GraphNode:
			remove_child(c)
			c.queue_free()
	_nodes.clear()
	_meta.clear()
	if _machine == null or _group.is_empty():
		return
	var mem := GroupModel.members(_machine, _group)
	var drawn := _compute_drawn(mem)
	_drawn = drawn
	_selected_edge = {}
	var layers := _compute_layers(mem, drawn)
	for s in mem:
		var node := _make_node(s, drawn[s])
		add_child(node)
		_nodes[s] = node
	_apply_layout(layers, drawn)
	for s in mem:
		var from_name := StringName((_nodes[s] as GraphNode).name)
		var edges: Array = drawn[s]
		for j in edges.size():
			var target: FrameState = edges[j]["target"]
			if target == s:
				continue  # self-loop: the row's round glyph carries it
			if _nodes.has(target):
				connect_node(from_name, 1 + j,
						StringName((_nodes[target] as GraphNode).name), 0)
	# The badge overlay rides above nodes and lines; (re)raise it last.
	if _layer == null:
		_layer = EdgeBadgeLayer.new()
		_layer.graph = self
		add_child(_layer)
		_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	move_child(_layer, get_child_count() - 1)


# ------------------------------------------------------- badge overlay ---

func get_drawn() -> Dictionary:
	return _drawn


func get_nodes() -> Dictionary:
	return _nodes


func get_selected_edge() -> Dictionary:
	return _selected_edge


func get_entry_state() -> FrameState:
	if _machine == null or _group.is_empty():
		return null
	return GroupModel.group_entry(_machine, _group, _analysis)


func badge_clicked(hit: Dictionary) -> void:
	_selected_edge = {"state": hit["state"], "index": hit["index"]}
	edge_selected.emit(hit["state"], hit["row"], hit["target"])


func badge_double_clicked(hit: Dictionary) -> void:
	badge_clicked(hit)
	dive_requested.emit(hit["state"])


## Drawn adjacency (local, in-group) — drives layout and wiring.
func _compute_drawn(mem: Array) -> Dictionary:
	var drawn := {}
	for s in mem:
		drawn[s] = GroupModel.drawn_rows(_machine, s, _group, _analysis)
	return drawn


## BFS layers from the group entry over drawn edges. States the drawn
## edges never reach share one final layer.
func _compute_layers(mem: Array, drawn: Dictionary) -> Dictionary:
	var entry := GroupModel.group_entry(_machine, _group, _analysis)
	var depth := {}
	if entry != null:
		depth[entry] = 0
		var queue: Array = [entry]
		while not queue.is_empty():
			var cur: FrameState = queue.pop_front()
			for e in drawn.get(cur, []):
				var t: FrameState = e["target"]
				if not depth.has(t):
					depth[t] = int(depth[cur]) + 1
					queue.append(t)
	var max_depth := 0
	for s in mem:
		if not depth.has(s):
			depth[s] = -1
		max_depth = maxi(max_depth, int(depth[s]))
	var unreached_depth := max_depth + 1
	for s in mem:
		if int(depth[s]) < 0:
			depth[s] = unreached_depth
	var layers := {}
	for s in mem:
		if not layers.has(depth[s]):
			layers[depth[s]] = []
		(layers[depth[s]] as Array).append(s)
	return layers


## Node positions for a layer ordering: layers become columns, wrapped
## into chunks of MAX_COL so no column runs away vertically. Columns
## are COL_DX apart with NODE_W-wide nodes, so columns never touch;
## within a column, measured heights + the golden-ratio ROW_DY stack
## nodes without touching. The layout is overlap-free for any ordering.
func _layout_positions(layers: Dictionary, heights: Dictionary) -> Dictionary:
	var out := {}
	var layer_keys: Array = layers.keys()
	layer_keys.sort()
	var vcol := 0
	for d in layer_keys:
		var col: Array = layers[d]
		var start := 0
		while start < col.size():
			var chunk: Array = col.slice(start, mini(start + MAX_COL, col.size()))
			var y := 64.0
			for s in chunk:
				out[s] = Vector2(56.0 + vcol * COL_DX, y)
				y += float(heights[s]) + ROW_DY
			vcol += 1
			start += MAX_COL
	return out


## Node heights that cannot overlap: each node's real minimum height
## (title + meta + rows + stylebox margins) floored by the old estimate,
## so a node that hasn't finished sizing still gets a safe height. The
## estimate alone undercounts self-loop glyph rows (21px real vs 8px
## assumed) and title/meta variance, which is how the old layout could
## stack two nodes on top of each other. With real heights the stack in
## _layout_positions guarantees no two nodes in a column touch, and
## COL_DX > NODE_W guarantees columns never touch — so beautify's
## crossing score needs no overlap term.
func _measured_heights(drawn: Dictionary) -> Dictionary:
	var h := {}
	for s in drawn.keys():
		var est := 54.0 + 8.0 * (drawn[s] as Array).size()
		var node := _nodes.get(s) as GraphNode
		var real := node.get_combined_minimum_size().y if node != null else 0.0
		h[s] = maxf(real, est)
	return h


## Position the existing nodes by layer order.
func _apply_layout(layers: Dictionary, drawn: Dictionary) -> void:
	var heights := _measured_heights(drawn)
	var positions := _layout_positions(layers, heights)
	for s in positions:
		(_nodes[s] as GraphNode).position_offset = positions[s]
	_content_size = Vector2.ZERO
	for s in positions:
		_content_size.x = maxf(_content_size.x, positions[s].x + NODE_W + 60.0)
		_content_size.y = maxf(_content_size.y, positions[s].y + float(heights[s]) + 60.0)


# ------------------------------------------------------------------ beautify ---

static func _seg_intersect(p1: Vector2, p2: Vector2, p3: Vector2, p4: Vector2) -> bool:
	var d1 := (p4 - p3).cross(p1 - p3)
	var d2 := (p4 - p3).cross(p2 - p3)
	var d3 := (p2 - p1).cross(p3 - p1)
	var d4 := (p2 - p1).cross(p4 - p1)
	return ((d1 > 0.0 and d2 < 0.0) or (d1 < 0.0 and d2 > 0.0)) \
			and ((d3 > 0.0 and d4 < 0.0) or (d3 < 0.0 and d4 > 0.0))


## One edge as GraphEdit draws it: a cubic bezier leaving the source port
## horizontally and entering the target port horizontally.
func _edge_points(from_pt: Vector2, to_pt: Vector2) -> PackedVector2Array:
	var bend := clampf(absf(to_pt.x - from_pt.x) * 0.5, 24.0, 400.0)
	var c1 := from_pt + Vector2(bend, 0.0)
	var c2 := to_pt - Vector2(bend, 0.0)
	var pts := PackedVector2Array()
	for j in 13:
		var t := j / 12.0
		var mt := 1.0 - t
		pts.append(mt * mt * mt * from_pt + 3.0 * mt * mt * t * c1
				+ 3.0 * mt * t * t * c2 + t * t * t * to_pt)
	return pts


## Geometric crossing count over the drawn edges for a candidate layout.
## Edge pairs sharing an endpoint are skipped (they meet at a port by
## construction). This counts what the eye sees: forward inversions,
## multi-span edges, and back-edge sweeps alike.
func _count_crossings_geo(positions: Dictionary, drawn: Dictionary,
		out_off: Dictionary, in_off: Dictionary) -> int:
	var polys: Array = []
	for s in drawn.keys():
		if not positions.has(s):
			continue
		var edges: Array = drawn[s]
		for j in edges.size():
			var target: FrameState = edges[j]["target"]
			if target == s:
				continue  # self-loops are glyphs now, not drawn lines
			if not positions.has(target):
				continue
			var fp: Vector2 = positions[s] + (out_off[s] as Array)[j]
			var tp: Vector2 = positions[target] + in_off[target]
			polys.append({"s": s, "t": target, "pts": _edge_points(fp, tp)})
	var total := 0
	for i in polys.size():
		for k in range(i + 1, polys.size()):
			var a: Dictionary = polys[i]
			var b: Dictionary = polys[k]
			if a["s"] == b["s"] or a["s"] == b["t"] \
					or a["t"] == b["s"] or a["t"] == b["t"]:
				continue
			var p: PackedVector2Array = a["pts"]
			var q: PackedVector2Array = b["pts"]
			for x in p.size() - 1:
				for y in q.size() - 1:
					if _seg_intersect(p[x], p[x + 1], q[y], q[y + 1]):
						total += 1
	return total


## Reorder states inside each layer (barycenter sweeps over the drawn
## edges, scored by the geometric crossing count, best-of kept) to
## minimize the crossings actually drawn, then re-layout. Overlap needs
## no score term: the layout is overlap-free by construction (measured
## heights + golden-ratio gaps), so every candidate ordering is safe.
## Returns {"before": int, "after": int} crossing counts.
func beautify() -> Dictionary:
	if _machine == null or _nodes.is_empty():
		return {"before": 0, "after": 0}
	var mem := GroupModel.members(_machine, _group)
	var drawn := _compute_drawn(mem)
	var layers := _compute_layers(mem, drawn)
	# Real port offsets (port indices are per-side ordinals: drawn edge j
	# leaves through output port j and enters through input port 0) and
	# measured node heights, which make the layout overlap-free for any
	# ordering (see _measured_heights).
	var out_off := {}
	var in_off := {}
	for s in mem:
		var node := _nodes[s] as GraphNode
		in_off[s] = node.get_input_port_position(0)
		var arr: Array = []
		for j in (drawn[s] as Array).size():
			arr.append(node.get_output_port_position(j))
		out_off[s] = arr
	var heights := _measured_heights(drawn)
	var positions := _layout_positions(layers, heights)
	var before := _count_crossings_geo(positions, drawn, out_off, in_off)
	var best := before
	var best_layers := _dup_layers(layers)
	# Undirected neighbor lists for the barycenter heuristic.
	var neighbors := {}
	for s in drawn.keys():
		if not neighbors.has(s):
			neighbors[s] = []
		for e in drawn[s]:
			var t: FrameState = e["target"]
			(neighbors[s] as Array).append(t)
			if not neighbors.has(t):
				neighbors[t] = []
			(neighbors[t] as Array).append(s)
	for round in 14:
		var keys: Array = layers.keys()
		keys.sort()
		if round % 2 == 1:
			keys.reverse()
		for d in keys:
			_sort_layer(layers, int(d), neighbors)
		positions = _layout_positions(layers, heights)
		var c := _count_crossings_geo(positions, drawn, out_off, in_off)
		if c < best:
			best = c
			best_layers = _dup_layers(layers)
		if best == 0:
			break
	var best_pos := _layout_positions(best_layers, heights)
	for s in best_pos:
		(_nodes[s] as GraphNode).position_offset = best_pos[s]
	_content_size = Vector2.ZERO
	for s in best_pos:
		_content_size.x = maxf(_content_size.x, best_pos[s].x + NODE_W + 60.0)
		_content_size.y = maxf(_content_size.y, best_pos[s].y + float(heights[s]) + 60.0)
	_settle_frames = 90
	set_process(true)
	return {"before": before, "after": best}


func _dup_layers(layers: Dictionary) -> Dictionary:
	var out := {}
	for d in layers.keys():
		out[d] = (layers[d] as Array).duplicate()
	return out


func _sort_layer(layers: Dictionary, d: int, neighbors: Dictionary) -> void:
	# Global scalar coordinate per state: layer dominates, index breaks.
	var coord := {}
	for dd in layers.keys():
		var arr: Array = layers[dd]
		for i in arr.size():
			coord[arr[i]] = int(dd) * 10000 + i
	var arr: Array = layers[d]
	arr.sort_custom(func(a: FrameState, b: FrameState) -> bool:
		return _barycenter(a, neighbors, coord) < _barycenter(b, neighbors, coord))
	layers[d] = arr


func _barycenter(s: FrameState, neighbors: Dictionary, coord: Dictionary) -> float:
	var ns: Array = neighbors.get(s, [])
	if ns.is_empty():
		return float(coord.get(s, 0))
	var sum := 0.0
	for t in ns:
		sum += float(coord.get(t, 0))
	return sum / ns.size()


func _make_node(s: FrameState, edges: Array) -> GraphNode:
	var node := GraphNode.new()
	node.name = "gstate_%d" % s.get_instance_id()
	node.title = s.state_name
	UEStyle.apply_graph_node(node, get_theme_default_font())
	node.custom_minimum_size = Vector2(NODE_W, 0)
	node.set_meta("state", s)
	var meta := Label.new()
	meta.text = _meta_text(s)
	meta.add_theme_font_size_override("font_size", 11)
	meta.add_theme_color_override("font_color", UEStyle.SUB)
	node.add_child(meta)
	node.set_slot(0, true, 0, COL_EDGE, false, 0, Color.WHITE)
	_meta[s] = meta
	for j in edges.size():
		var row: Control
		if edges[j]["target"] == s:
			# Self-transition: a round loop glyph in the row instead of
			# a GraphEdit self-connection (refresh skips wiring it).
			row = SelfLoopGlyph.new()
		else:
			row = Control.new()
			row.custom_minimum_size = Vector2(8, 7)
		node.add_child(row)
		node.set_slot(1 + j, false, 0, Color.WHITE, true, 0, COL_EDGE)
	return node


func _meta_text(s: FrameState) -> String:
	var text := "%df · %d rows" % [s.duration_frames, s.transitions.size()]
	var in_sh := int((_analysis.get("in_shared", {}) as Dictionary).get(s.state_name, 0))
	var out_sh := int((_analysis.get("out_shared", {}) as Dictionary).get(s.state_name, 0))
	if in_sh >= 5:
		text += " · ⇢%d" % in_sh
	if out_sh >= 2:
		text += " · R×%d" % out_sh
	return text


## Rebuild meta lines in place (inspector edits; no node rebuild).
func update_labels() -> void:
	for s in _meta.keys():
		(_meta[s] as Label).text = _meta_text(s)


func _on_node_selected(node: Node) -> void:
	if _editor == null or not node.has_meta("state"):
		return
	var s: FrameState = node.get_meta("state")
	_editor.edit_resource(s)
	var now := Time.get_ticks_msec()
	if s == _last_pick_state and now - _last_pick_msec < 400:
		dive_requested.emit(s)
	_last_pick_state = s
	_last_pick_msec = now


# ------------------------------------------------------------------ preview ---

func highlight_active(player: BehaviorPlayer) -> void:
	if player == null or _machine == null:
		return
	var active := player.current_state_name(_machine.machine_name)
	for s in _nodes.keys():
		(_nodes[s] as GraphNode).self_modulate = \
				Color(1.6, 1.4, 1.0) if s.state_name == active else Color.WHITE


func clear_highlight() -> void:
	for s in _nodes.keys():
		(_nodes[s] as GraphNode).self_modulate = Color.WHITE
