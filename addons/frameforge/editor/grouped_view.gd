@tool
extends VBoxContainer
## Grouped sub-machine view: group map (superstates + aggregated flows)
## on top; below it, the selected group's states in a detail graph with
## border-port chips for its cross-group entries and exits.

const MAP_SCRIPT := "res://addons/frameforge/editor/group_map.gd"
const DETAIL_SCRIPT := "res://addons/frameforge/editor/group_detail_graph.gd"
const GroupModel := preload("res://addons/frameforge/editor/group_model.gd")

var _machine: SubStateMachine = null
var _editor: Control = null
var _analysis: Dictionary = {}
var _group := ""

var _map: Control
var _detail: GraphEdit
var _title: Label
var _status: Label
var _entries_box: VBoxContainer
var _exits_box: VBoxContainer
var _edge_info: Label


func setup(machine: SubStateMachine, editor: Control) -> void:
	_machine = machine
	_editor = editor
	_analysis = GroupModel.analyze(machine)
	_build_ui()
	_group = GroupModel.group_of(machine.entry_state) if machine.entry_state != null else ""
	if _group.is_empty():
		var names := GroupModel.group_names(machine, _analysis)
		_group = names[0] if not names.is_empty() else ""
	_apply_group()


func _build_ui() -> void:
	_map = (load(MAP_SCRIPT) as GDScript).new()
	_map.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_map.size_flags_stretch_ratio = 5.0
	add_child(_map)
	_map.setup(_machine, _analysis)
	_map.group_selected.connect(_on_group_selected)

	add_child(HSeparator.new())

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	add_child(header)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 14)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_title)
	var legend := Label.new()
	legend.text = "— flow · gold count = shared rule (counted once) · ⇢ shared in · R× rule rows · ◉ on a line = its condition — click it"
	legend.add_theme_font_size_override("font_size", 11)
	legend.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
	header.add_child(legend)
	_status = Label.new()
	_status.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
	header.add_child(_status)
	var beautify_btn := Button.new()
	beautify_btn.text = "Beautify"
	beautify_btn.focus_mode = Control.FOCUS_NONE
	beautify_btn.tooltip_text = "Rearrange group boxes and reorder states in the expanded group to minimize line crossings"
	beautify_btn.pressed.connect(_on_beautify)
	header.add_child(beautify_btn)

	var bottom := HBoxContainer.new()
	bottom.size_flags_vertical = Control.SIZE_EXPAND_FILL
	bottom.size_flags_stretch_ratio = 5.0
	bottom.add_theme_constant_override("separation", 8)
	add_child(bottom)

	_detail = (load(DETAIL_SCRIPT) as GDScript).new()
	_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(_detail)
	_detail.dive_requested.connect(_on_dive_requested)
	_detail.edge_selected.connect(_on_edge_selected)

	var side := VBoxContainer.new()
	side.custom_minimum_size = Vector2(248, 0)
	side.add_theme_constant_override("separation", 4)
	bottom.add_child(side)

	var entries_title := Label.new()
	entries_title.text = "← entries"
	side.add_child(entries_title)
	_entries_box = VBoxContainer.new()
	_entries_box.add_theme_constant_override("separation", 3)
	side.add_child(_entries_box)

	var exits_title := Label.new()
	exits_title.text = "exits →"
	side.add_child(exits_title)
	_exits_box = VBoxContainer.new()
	_exits_box.add_theme_constant_override("separation", 3)
	side.add_child(_exits_box)

	var note := Label.new()
	note.text = "Outside connections land on border ports — they never cross the group's interior."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
	side.add_child(note)

	side.add_child(HSeparator.new())
	_edge_info = Label.new()
	_edge_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_edge_info.visible = false
	side.add_child(_edge_info)


func _on_edge_selected(state: FrameState, row: FFTransition,
		target: FrameState) -> void:
	if state == null or row == null:
		_edge_info.visible = false
		return
	var summary: String = (load("res://addons/frameforge/editor/state_graph_node.gd")
			as GDScript)._cond_summary(row.condition)
	_edge_info.text = "%s → %s\n%s" % [state.state_name,
			target.state_name if target != null else "?", summary]
	_edge_info.visible = true


func _apply_group() -> void:
	if _group.is_empty():
		return
	if _edge_info != null:
		_edge_info.visible = false
	_title.text = "%s — expanded" % _group.to_upper()
	_map.set_selected(_group)
	_detail.setup(_machine, _editor, _group, _analysis)
	_rebuild_chips()


func _rebuild_chips() -> void:
	for c in _entries_box.get_children():
		c.queue_free()
	for c in _exits_box.get_children():
		c.queue_free()
	var entries_l: Dictionary = (_analysis.get("entries_local", {}) as Dictionary).get(_group, {})
	var entries_s: Dictionary = (_analysis.get("entries_shared", {}) as Dictionary).get(_group, {})
	var exits_l: Dictionary = (_analysis.get("exits_local", {}) as Dictionary).get(_group, {})
	var exits_s: Dictionary = (_analysis.get("exits_shared", {}) as Dictionary).get(_group, {})
	for src in _sorted_keys(entries_l, entries_s):
		var label := "%s →  ×%d" % [src, int(entries_l.get(src, 0))]
		if int(entries_s.get(src, 0)) > 0:
			label += " (+%d shared)" % int(entries_s[src])
		_entries_box.add_child(_chip(label, src))
	if entries_l.is_empty() and entries_s.is_empty():
		_entries_box.add_child(_dim_label("(none)"))
	for dst in _sorted_keys(exits_l, exits_s):
		var label := "→ %s  ×%d" % [dst, int(exits_l.get(dst, 0))]
		if int(exits_s.get(dst, 0)) > 0:
			label += " (+%d shared)" % int(exits_s[dst])
		_exits_box.add_child(_chip(label, dst))
	if exits_l.is_empty() and exits_s.is_empty():
		_exits_box.add_child(_dim_label("(none)"))


func _sorted_keys(a: Dictionary, b: Dictionary) -> Array:
	var keys := {}
	for k in a.keys():
		keys[k] = true
	for k in b.keys():
		keys[k] = true
	var out: Array = keys.keys()
	out.sort_custom(func(x: String, y: String) -> bool:
		var tx := int(a.get(x, 0)) + int(b.get(x, 0))
		var ty := int(a.get(y, 0)) + int(b.get(y, 0))
		return tx > ty if tx != ty else x < y)
	return out


func _chip(label: String, group: String) -> Button:
	var b := Button.new()
	b.text = label
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(_on_group_selected.bind(group))
	return b


func _dim_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	return l


func _on_group_selected(group: String) -> void:
	_group = group
	_status.text = ""
	_apply_group()


func _on_beautify() -> void:
	var rm: Dictionary = _map.beautify() if is_instance_valid(_map) \
			and _map.has_method("beautify") else {}
	var rd: Dictionary = _detail.beautify() if is_instance_valid(_detail) \
			and _detail.has_method("beautify") else {}
	_status.text = "crossings — map %d → %d · group %d → %d" % [
		int(rm.get("before", 0)), int(rm.get("after", 0)),
		int(rd.get("before", 0)), int(rd.get("after", 0))]


func _on_dive_requested(state: FrameState) -> void:
	if _editor != null and _editor.has_method("dive_to_state"):
		_editor.dive_to_state(_machine, state)


# ------------------------------------------------------------------ editor hooks ---

func refresh() -> void:
	if _machine == null:
		return
	_analysis = GroupModel.analyze(_machine)
	var names := GroupModel.group_names(_machine, _analysis)
	if not names.has(_group):
		_group = names[0] if not names.is_empty() else ""
	_map.setup(_machine, _analysis)
	_apply_group()


func update_labels() -> void:
	if is_instance_valid(_detail) and _detail.has_method("update_labels"):
		_detail.update_labels()


func highlight_active(player: BehaviorPlayer) -> void:
	if is_instance_valid(_detail) and _detail.has_method("highlight_active"):
		_detail.highlight_active(player)


func clear_highlight() -> void:
	if is_instance_valid(_detail) and _detail.has_method("clear_highlight"):
		_detail.clear_highlight()
