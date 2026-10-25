@tool
extends GraphNode
## GraphNode for one FrameState: input port, inline duration/displacement,
## one output port per transition row, add-row button.

const UEStyle := preload("res://addons/frameforge/editor/ue_style.gd")

var _state: FrameState = null
var _editor: Control = null
var _row_labels: Array[Label] = []
var _is_entry := false
var _use_seconds := false
var _dur_spin: SpinBox = null


func setup(s: FrameState, editor: Control, graph: GraphEdit) -> void:
	_state = s
	_editor = editor
	_use_seconds = bool(editor.get("use_seconds"))
	_is_entry = graph.get("_machine") != null and (graph.get("_machine") as SubStateMachine).entry_state == s
	_build()
	update_labels()


func get_state() -> FrameState:
	return _state


func _ready() -> void:
	UEStyle.apply_graph_node(self, get_theme_default_font())


func _build() -> void:
	# Slot 0: input row.
	var in_row := HBoxContainer.new()
	var in_label := Label.new()
	in_label.text = "in" + ("  ▶ entry" if _is_entry else "")
	in_row.add_child(in_label)
	add_child(in_row)
	set_slot(0, true, 0, UEStyle.LINE, false, 0, Color.WHITE)

	# Slot 1: inline timing fields (no ports).
	var fields := HBoxContainer.new()
	fields.add_theme_constant_override("separation", 4)
	var dur_label := Label.new()
	dur_label.text = "dur"
	fields.add_child(dur_label)
	var dur := SpinBox.new()
	if _use_seconds:
		dur.min_value = 1.0 / 60.0
		dur.max_value = 600.0
		dur.step = 1.0 / 60.0
		dur.value = _state.duration_frames / 60.0
	else:
		dur.min_value = 1
		dur.max_value = 600
		dur.step = 1
		dur.value = _state.duration_frames
	dur.custom_minimum_size = Vector2(64, 0)
	dur.value_changed.connect(_on_dur_changed)
	_dur_spin = dur
	fields.add_child(dur)
	var disp_label := Label.new()
	disp_label.text = "disp"
	fields.add_child(disp_label)
	var disp := SpinBox.new()
	disp.min_value = 0
	disp.max_value = 100
	disp.step = 0.05
	disp.value = _state.displacement
	disp.custom_minimum_size = Vector2(56, 0)
	disp.value_changed.connect(_on_disp_changed)
	fields.add_child(disp)
	add_child(fields)
	set_slot(1, false, 0, Color.WHITE, false, 0, Color.WHITE)

	# Slots 2..: one output port per transition row.
	for i in _state.transitions.size():
		add_child(_make_row(i))
		set_slot(2 + i, false, 0, Color.WHITE, true, 0, UEStyle.LINE)

	# Last slot: add-row button (no ports).
	var add_row := Button.new()
	add_row.text = "+ Row"
	add_row.focus_mode = Control.FOCUS_NONE
	add_row.pressed.connect(_on_add_row)
	add_child(add_row)
	set_slot(2 + _state.transitions.size(), false, 0, Color.WHITE, false, 0, Color.WHITE)

	_row_labels.clear()
	for i in _state.transitions.size():
		_row_labels.append(get_child(2 + i).get_node("Summary") as Label)


func _make_row(i: int) -> HBoxContainer:
	var row: FFTransition = _state.transitions[i]
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 4)

	var up := Button.new()
	up.text = "↑"
	up.focus_mode = Control.FOCUS_NONE
	up.pressed.connect(_on_row_up.bind(i))
	hb.add_child(up)
	var down := Button.new()
	down.text = "↓"
	down.focus_mode = Control.FOCUS_NONE
	down.pressed.connect(_on_row_down.bind(i))
	hb.add_child(down)

	var summary := Label.new()
	summary.name = "Summary"
	summary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	summary.mouse_filter = Control.MOUSE_FILTER_STOP
	summary.gui_input.connect(_on_row_clicked.bind(i))
	hb.add_child(summary)

	var badge := Label.new()
	badge.name = "Badge"
	if row != null:
		if row.momentum == FFTransition.Momentum.PRESERVE:
			badge.text = "〜%d" % row.blend_frames
		else:
			badge.text = "✂"
	hb.add_child(badge)

	var clear := Button.new()
	clear.text = "×"
	clear.focus_mode = Control.FOCUS_NONE
	clear.tooltip_text = "Clear target"
	clear.pressed.connect(_on_row_clear.bind(i))
	hb.add_child(clear)
	return hb


func update_labels() -> void:
	title = _state.state_name
	if not _state.logic.is_empty():
		title += " [%s]" % _state.logic
	if _state.steer != null:
		title += " [steer]"
	for i in _row_labels.size():
		if i < _state.transitions.size():
			_row_labels[i].text = _row_summary(_state.transitions[i])


func _row_summary(row: FFTransition) -> String:
	if row == null:
		return "—"
	var c := "?"
	if row.condition != null:
		c = _cond_summary(row.condition)
	var t := "∅"
	if not String(row.target_state_name).is_empty():
		t = String(row.target_state_name)
	elif row.target_behavior != null:
		t = "[" + row.target_behavior.behavior_name + "]"
	return "%s → %s" % [c, t]


static func _cond_summary(cond: FFCondition) -> String:
	if cond == null:
		return "?"
	if not cond.all_of.is_empty():
		var all_parts := []
		for k in cond.all_of:
			all_parts.append(_cond_summary(k))
		return "all(%s)" % ", ".join(all_parts)
	if not cond.any_of.is_empty():
		var any_parts := []
		for k in cond.any_of:
			any_parts.append(_cond_summary(k))
		return "any(%s)" % ", ".join(any_parts)
	match cond.type:
		FFCondition.Type.ON_COMPLETE:
			return "On Complete"
		FFCondition.Type.ON_INPUT:
			var mode := "pressed"
			match cond.input_mode:
				FFCondition.InputMode.ANY_RELEASED:
					mode = "released"
				FFCondition.InputMode.ALL_RELEASED:
					mode = "all released"
				FFCondition.InputMode.ANY_HELD:
					mode = "held"
				FFCondition.InputMode.NONE_HELD:
					mode = "none held"
			var text := "Input %s (%s)" % [", ".join(cond.input_actions), mode]
			if cond.buffer_ticks > 0:
				text += " +buf %d" % cond.buffer_ticks
			return text
		FFCondition.Type.ON_STICK:
			return "Stick r≥%.2f ∠%.0f–%.0f° vs %s" % [
				cond.stick_radius_min, cond.stick_angle_min_deg,
				cond.stick_angle_max_deg,
				"vel" if cond.stick_angle_vs == FFCondition.StickAngleVs.VELOCITY else "facing"]
		FFCondition.Type.ON_VARIABLE:
			var op := "?"
			match cond.param_op:
				FFCondition.Op.EQ:
					op = "=="
				FFCondition.Op.NE:
					op = "!="
				FFCondition.Op.GT:
					op = ">"
				FFCondition.Op.GE:
					op = ">="
				FFCondition.Op.LT:
					op = "<"
				FFCondition.Op.LE:
					op = "<="
			return "Var %s %s %s" % [cond.param_name, op, str(cond.param_value)]
		FFCondition.Type.ON_EVENT:
			return "Event: %s" % cond.event_name
		FFCondition.Type.ON_STATE:
			var m := String(cond.target_machine_name) if not String(cond.target_machine_name).is_empty() else "?"
			var s := String(cond.target_state_name) if not String(cond.target_state_name).is_empty() else "?"
			return "State: %s/%s" % [m, s]
		FFCondition.Type.ON_CUSTOM:
			return "Custom: %s" % cond.custom_name
	return "?"


# ------------------------------------------------------------------ actions ---

func _on_dur_changed(v: float) -> void:
	if _use_seconds:
		var frames := maxi(1, int(round(v * 60.0)))
		_state.duration_frames = frames
		_dur_spin.set_value_no_signal(frames / 60.0)
	else:
		_state.duration_frames = int(v)
	if _editor != null:
		_editor.mark_dirty()


func _on_disp_changed(v: float) -> void:
	_state.displacement = v
	if _editor != null:
		_editor.mark_dirty()


func _on_add_row() -> void:
	if _editor != null:
		_editor.do_add_row(_state)


func _on_row_up(i: int) -> void:
	if _editor != null and i > 0:
		_editor.do_move_row(_state, i, i - 1)


func _on_row_down(i: int) -> void:
	if _editor != null and i < _state.transitions.size() - 1:
		_editor.do_move_row(_state, i, i + 1)


func _on_row_clear(i: int) -> void:
	if _editor == null or i < 0 or i >= _state.transitions.size():
		return
	var row: FFTransition = _state.transitions[i]
	if not String(row.target_state_name).is_empty() or row.target_behavior != null:
		_editor.do_connect_row(row, null)


func _on_row_clicked(event: InputEvent, i: int) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed and _editor != null:
			if i >= 0 and i < _state.transitions.size():
				_editor.edit_resource(_state.transitions[i])
