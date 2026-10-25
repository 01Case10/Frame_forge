@tool
extends GraphEdit
## GraphEdit canvas for one SubStateMachine: state nodes, transition
## wiring, comment frames. Structural edits go through the editor's
## undo helpers; node positions write straight to state.editor_position.

const NODE_SCRIPT := "res://addons/frameforge/editor/state_graph_node.gd"
const UEStyle := preload("res://addons/frameforge/editor/ue_style.gd")
const GraphArrowLayer := preload("res://addons/frameforge/editor/graph_arrow_layer.gd")

var _machine: SubStateMachine = null
var _editor: Control = null
var _nodes := {}  # FrameState -> GraphNode
var _frames := {}  # FFComment -> GraphFrame
var _suppress_pos_write := false
var _arrows: Control = null


func _init() -> void:
	UEStyle.apply_graph_canvas(self)


func setup(machine: SubStateMachine, editor: Control) -> void:
	_machine = machine
	_editor = editor
	connection_request.connect(_on_connection_request)
	disconnection_request.connect(_on_disconnection_request)
	connection_to_empty.connect(_on_connection_to_empty)
	delete_nodes_request.connect(_on_delete_nodes_request)
	node_selected.connect(_on_node_selected)
	node_deselected.connect(_on_node_deselected)
	popup_request.connect(_on_popup_request)
	refresh()


func refresh() -> void:
	_suppress_pos_write = true
	for c in get_children():
		if c is GraphNode or c is GraphFrame:
			remove_child(c)
			c.queue_free()
	_nodes.clear()
	_frames.clear()
	if _machine == null:
		_suppress_pos_write = false
		return
	for cmt in _machine.editor_comments:
		if cmt != null:
			_add_comment_frame(cmt)
	for s in _machine.states:
		if s == null:
			continue
		var node := _make_node(s)
		add_child(node)
		_nodes[s] = node
	# Rebuild connections from transition rows (name-based lookup).
	for s in _machine.states:
		if s == null or not _nodes.has(s):
			continue
		var from_name := StringName((_nodes[s] as GraphNode).name)
		for i in s.transitions.size():
			var row: FFTransition = s.transitions[i]
			if row != null and not String(row.target_state_name).is_empty():
				var target := _find_state(row.target_state_name)
				if target != null and _nodes.has(target):
					var to_name := StringName((_nodes[target] as GraphNode).name)
					connect_node(from_name, 2 + i, to_name, 0)
	if _arrows == null:
		_arrows = GraphArrowLayer.new()
		_arrows.graph = self
		add_child(_arrows)
		_arrows.set_anchors_preset(Control.PRESET_FULL_RECT)
	move_child(_arrows, get_child_count() - 1)
	_suppress_pos_write = false


func canvas_center() -> Vector2:
	var local := size * 0.5
	var p := (local + scroll_offset) / zoom
	if _editor != null and _editor.is_snap_enabled():
		p = (p / 20.0).round() * 20.0
	return p


# ------------------------------------------------------------------ nodes ---

func _make_node(s: FrameState) -> GraphNode:
	var script := load(NODE_SCRIPT) as GDScript
	var node := script.new() as GraphNode
	node.name = "state_%d" % s.get_instance_id()
	node.setup(s, _editor, self)
	node.position_offset = s.editor_position
	node.position_offset_changed.connect(_on_node_moved.bind(node))
	return node


func _on_node_moved(node: GraphNode) -> void:
	if _suppress_pos_write or _editor == null:
		return
	var s: FrameState = node.get("state")
	if s != null:
		s.editor_position = node.position_offset
		_editor.mark_dirty()


func find_node(state: FrameState) -> GraphNode:
	return _nodes.get(state, null)


## Update node titles/row labels in place (inspector edits, no rebuild).
func update_labels() -> void:
	for s in _nodes.keys():
		var node: GraphNode = _nodes[s]
		if node.has_method("update_labels"):
			node.update_labels()


# ------------------------------------------------------------------ comments ---

func _add_comment_frame(c: FFComment) -> void:
	var f := GraphFrame.new()
	f.name = "comment_%d" % c.get_instance_id()
	f.title = c.title
	f.position_offset = c.position
	f.size = c.size
	f.set_meta("comment", c)
	add_child(f)
	_frames[c] = f
	f.position_offset_changed.connect(_on_frame_moved.bind(f))
	f.resized.connect(_on_frame_resized.bind(f))


func _on_frame_moved(f: GraphFrame) -> void:
	if _suppress_pos_write or _editor == null:
		return
	var c: FFComment = f.get_meta("comment")
	if c == null:
		return
	var delta := f.position_offset - c.position
	c.position = f.position_offset
	c.title = f.title
	if delta.length_squared() > 0.01:
		# Move enclosed states together with the frame.
		var rect := Rect2(f.position_offset - delta, f.size)
		for s in _machine.states:
			if s != null and rect.has_point(s.editor_position + Vector2(90, 20)):
				s.editor_position += delta
				if _nodes.has(s):
					(_nodes[s] as GraphNode).position_offset = s.editor_position
	_editor.mark_dirty()


func _on_frame_resized(f: GraphFrame) -> void:
	if _suppress_pos_write or _editor == null:
		return
	var c: FFComment = f.get_meta("comment")
	if c != null:
		c.size = f.size
		_editor.mark_dirty()


# ------------------------------------------------------------------ wiring ---

func _state_of(node_name: StringName) -> FrameState:
	var node := get_node_or_null(NodePath(node_name))
	if node != null and node.has_method("get_state"):
		return node.get_state()
	return null


func _find_state(state_name: StringName) -> FrameState:
	if _machine == null:
		return null
	for s in _machine.states:
		if s != null and s.state_name == state_name:
			return s
	return null


func _on_connection_request(from_node: StringName, from_port: int, to_node: StringName, to_port: int) -> void:
	if _editor == null:
		return
	if from_port < 2 or to_port != 0:
		return
	var from_state := _state_of(from_node)
	var to_state := _state_of(to_node)
	if from_state == null or to_state == null:
		return
	var row_idx := from_port - 2
	if row_idx < 0 or row_idx >= from_state.transitions.size():
		return
	var row: FFTransition = from_state.transitions[row_idx]
	_editor.do_connect_row(row, to_state)


func _on_disconnection_request(_from_node: StringName, _from_port: int, _to_node: StringName, _to_port: int) -> void:
	pass  # disconnects go through connection_to_empty / row × buttons


func _on_connection_to_empty(from_node: StringName, from_port: int, _release_position: Vector2) -> void:
	# Drag a connected row port to empty space: clear its target.
	if _editor == null or from_port < 2:
		return
	var from_state := _state_of(from_node)
	if from_state == null:
		return
	var row_idx := from_port - 2
	if row_idx < 0 or row_idx >= from_state.transitions.size():
		return
	var row: FFTransition = from_state.transitions[row_idx]
	if String(row.target_state_name).is_empty():
		_editor.do_connect_row(row, null)


func _on_delete_nodes_request(node_names: Array) -> void:
	if _editor == null:
		return
	var states: Array = []
	for n in node_names:
		var s := _state_of(n)
		if s != null:
			states.append(s)
	_editor.do_delete_states(_machine, states)


func _on_node_selected(node: Node) -> void:
	if _editor == null:
		return
	if node.has_method("get_state"):
		_editor.edit_resource(node.get_state())
	elif node is GraphFrame and node.has_meta("comment"):
		_editor.edit_resource(node.get_meta("comment"))


func _on_node_deselected(_node: Node) -> void:
	pass


func _on_popup_request(_position: Vector2) -> void:
	if _editor == null:
		return
	var local := get_local_mouse_position()
	var p := (local + scroll_offset) / zoom
	if _editor.is_snap_enabled():
		p = (p / 20.0).round() * 20.0
	_editor.do_add_state(_machine, p)


func _unhandled_key_input(event: InputEvent) -> void:
	if _editor == null:
		return
	var dir := Vector2.ZERO
	if event.is_action_pressed("ui_left"):
		dir = Vector2(-1, 0)
	elif event.is_action_pressed("ui_right"):
		dir = Vector2(1, 0)
	elif event.is_action_pressed("ui_up"):
		dir = Vector2(0, -1)
	elif event.is_action_pressed("ui_down"):
		dir = Vector2(0, 1)
	if dir == Vector2.ZERO:
		return
	var step := 20.0 if _editor.is_snap_enabled() else 1.0
	var moved := false
	for s in _nodes.keys():
		var node: GraphNode = _nodes[s]
		if node.selected:
			s.editor_position += dir * step
			node.position_offset = s.editor_position
			moved = true
	if moved:
		_editor.mark_dirty()
		accept_event()


# ------------------------------------------------------------------ preview ---

func highlight_active(player: BehaviorPlayer) -> void:
	if player == null or _machine == null:
		return
	var active := player.current_state_name(_machine.machine_name)
	for s in _nodes.keys():
		var node: GraphNode = _nodes[s]
		node.self_modulate = Color(1.6, 1.4, 1.0) if s.state_name == active else Color.WHITE


func clear_highlight() -> void:
	for s in _nodes.keys():
		(_nodes[s] as GraphNode).self_modulate = Color.WHITE


## Select a state node and center the canvas on it (validation click-to-pan).
func focus_state(s: FrameState) -> void:
	var node: GraphNode = _nodes.get(s)
	if node == null:
		return
	for n in _nodes.values():
		(n as GraphNode).selected = false
	node.selected = true
	scroll_offset = node.position_offset * zoom - size * 0.5
