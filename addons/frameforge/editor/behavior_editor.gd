@tool
extends VBoxContainer
## FrameForge main-screen editor: toolbar, behavior overview / sub-machine
## graph views, breadcrumb, inspector retargeting, and preview.
##
## Phase 4a: shell + file ops + view switching. 4b: overview. 4c: graph.
## 4d: wiring. 4e: inspector. 4f: preview.

const OVERVIEW_SCRIPT := "res://addons/frameforge/editor/behavior_overview.gd"
const GRAPH_SCRIPT := "res://addons/frameforge/editor/sub_machine_graph.gd"
const GROUPED_SCRIPT := "res://addons/frameforge/editor/grouped_view.gd"
const MONITOR_SCRIPT := "res://addons/frameforge/editor/event_monitor.gd"
const VALIDATION_SCRIPT := "res://addons/frameforge/editor/validation_panel.gd"
const VALIDATOR_SCRIPT := "res://addons/frameforge/editor/ff_validator.gd"

var _ei: EditorInterface = null
var _undo_redo: EditorUndoRedoManager = null

var _behavior: FrameBehavior = null
var _behavior_path: String = ""
var _dirty := false

var _name_label: Label
var _tabs: HBoxContainer
var _breadcrumb: HBoxContainer
var _view_host: Control
var _overview: Control = null
var _graph: Control = null
var _grouped: Control = null
var _grouped_mode := false
var _grouped_button: Button
var _current_machine: SubStateMachine = null  # null = overview
var _snap_button: Button
var _units_button: Button
var use_seconds := false
var _monitor: Control = null
var _validation_panel: Control = null

var _preview_player: BehaviorPlayer = null
var _preview_timer: Timer = null
var _previewing := false
var _open_dialog: EditorFileDialog = null
var _save_dialog: EditorFileDialog = null


func setup(ei: EditorInterface, undo_redo: EditorUndoRedoManager) -> void:
	_ei = ei
	_undo_redo = undo_redo


func _ready() -> void:
	_build_ui()
	_ei.get_inspector().property_edited.connect(_on_inspector_property_edited)
	show_overview()


# ------------------------------------------------------------------ UI build ---

func _build_ui() -> void:
	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", 6)
	add_child(toolbar)

	var title := Label.new()
	title.text = "FrameForge"
	toolbar.add_child(title)

	_name_label = Label.new()
	_name_label.text = "<no behavior>"
	toolbar.add_child(_name_label)

	for spec in [["New", _on_new], ["Open", _on_open], ["Save", _on_save]]:
		var b := Button.new()
		b.text = spec[0]
		b.pressed.connect(spec[1])
		toolbar.add_child(b)

	var sep1 := VSeparator.new()
	toolbar.add_child(sep1)

	_tabs = HBoxContainer.new()
	_tabs.add_theme_constant_override("separation", 2)
	toolbar.add_child(_tabs)

	var sep2 := VSeparator.new()
	toolbar.add_child(sep2)

	for spec in [["Add State", _on_add_state], ["Add Comment", _on_add_comment]]:
		var b := Button.new()
		b.text = spec[0]
		b.pressed.connect(spec[1])
		toolbar.add_child(b)

	_units_button = Button.new()
	_units_button.text = "frames"
	_units_button.toggle_mode = true
	_units_button.tooltip_text = "Display units: frames | seconds (resources always store frames)"
	_units_button.toggled.connect(_on_units_toggled)
	toolbar.add_child(_units_button)

	_snap_button = Button.new()
	_snap_button.text = "Snap"
	_snap_button.toggle_mode = true
	_snap_button.button_pressed = true
	toolbar.add_child(_snap_button)

	_grouped_button = Button.new()
	_grouped_button.text = "Grouped"
	_grouped_button.toggle_mode = true
	_grouped_button.tooltip_text = "Grouped view: superstates with aggregated flows, one group expanded below"
	_grouped_button.toggled.connect(_on_grouped_toggled)
	toolbar.add_child(_grouped_button)

	var validate_button := Button.new()
	validate_button.text = "Validate"
	validate_button.pressed.connect(validate)
	toolbar.add_child(validate_button)

	var preview_button := Button.new()
	preview_button.text = "Preview"
	preview_button.toggle_mode = true
	preview_button.toggled.connect(_on_preview_toggled)
	toolbar.add_child(preview_button)

	_breadcrumb = HBoxContainer.new()
	_breadcrumb.add_theme_constant_override("separation", 4)
	add_child(_breadcrumb)

	_view_host = PanelContainer.new()
	_view_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_view_host.clip_contents = true
	add_child(_view_host)

	_preview_timer = Timer.new()
	_preview_timer.wait_time = 0.1
	_preview_timer.timeout.connect(_on_preview_step)
	add_child(_preview_timer)


func _clear_view_host() -> void:
	for c in _view_host.get_children():
		_view_host.remove_child(c)
		c.queue_free()
	_overview = null
	_graph = null
	_grouped = null


# ------------------------------------------------------------------ file ops ---

func _on_new() -> void:
	_stop_preview()
	var bh := FrameBehavior.new()
	bh.behavior_name = "NewBehavior"
	var m := SubStateMachine.new()
	m.machine_name = "Machine1"
	var s := FrameState.new()
	s.state_name = "State1"
	s.duration_frames = 1
	var states: Array[FrameState] = [s]
	m.states = states
	m.entry_state = s
	var machines: Array[SubStateMachine] = [m]
	bh.sub_machines = machines
	_load_behavior(bh, "")


func _on_open() -> void:
	if _open_dialog == null:
		_open_dialog = EditorFileDialog.new()
		_open_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
		_open_dialog.add_filter("*.json", "FrameForge behaviors")
		_open_dialog.file_selected.connect(_on_open_file)
		add_child(_open_dialog)
	_open_dialog.popup_centered_ratio(0.6)


func _on_open_file(path: String) -> void:
	_stop_preview()
	var bh := BehaviorJSON.load_behavior(path)
	if bh != null:
		_load_behavior(bh, path)
	else:
		push_error("FrameForge: not a FrameForge behavior JSON: " + path)


func _on_save() -> void:
	if _behavior == null:
		return
	if _behavior_path.is_empty():
		if _save_dialog == null:
			_save_dialog = EditorFileDialog.new()
			_save_dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
			_save_dialog.add_filter("*.json", "FrameForge behaviors")
			_save_dialog.file_selected.connect(_on_save_file)
			add_child(_save_dialog)
		_save_dialog.popup_centered_ratio(0.6)
	else:
		_save_behavior(_behavior_path)


func _on_save_file(path: String) -> void:
	if not path.ends_with(".json"):
		path += ".json"
	_save_behavior(path)


func _save_behavior(path: String) -> void:
	var err := BehaviorJSON.save_behavior(_behavior, path)
	if err != OK:
		push_error("FrameForge: save failed: " + path)
		return
	_behavior_path = path
	_dirty = false
	_refresh_chrome()
	validate()


func _load_behavior(bh: FrameBehavior, path: String) -> void:
	_stop_preview()
	_behavior = bh
	_behavior_path = path
	_dirty = false
	_current_machine = null
	edit_resource(bh)
	_refresh_chrome()
	show_overview()


# ------------------------------------------------------------------ chrome ---

func _refresh_chrome() -> void:
	if _behavior == null:
		_name_label.text = "<no behavior>"
	else:
		var star := "*" if _dirty else ""
		var fname := _behavior_path.get_file() if not _behavior_path.is_empty() else "(unsaved)"
		_name_label.text = "%s%s — %s" % [_behavior.behavior_name, star, fname]
	_refresh_tabs()
	_refresh_breadcrumb()


func _refresh_tabs() -> void:
	for c in _tabs.get_children():
		c.queue_free()
	if _behavior == null:
		return
	var overview_btn := _make_tab("Overview", _current_machine == null)
	overview_btn.pressed.connect(show_overview)
	_tabs.add_child(overview_btn)
	for m in _behavior.sub_machines:
		if m == null:
			continue
		var b := _make_tab(m.machine_name, m == _current_machine)
		b.pressed.connect(_on_tab_machine.bind(m))
		_tabs.add_child(b)


func _make_tab(text: String, active: bool) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.button_pressed = active
	b.focus_mode = Control.FOCUS_NONE
	return b


func _on_tab_machine(m: SubStateMachine) -> void:
	show_machine(m)


func _refresh_breadcrumb() -> void:
	for c in _breadcrumb.get_children():
		c.queue_free()
	if _behavior == null:
		return
	var root := Button.new()
	root.text = _behavior.behavior_name
	root.flat = true
	root.pressed.connect(show_overview)
	_breadcrumb.add_child(root)
	if _current_machine != null:
		var sep := Label.new()
		sep.text = "/"
		_breadcrumb.add_child(sep)
		var leaf := Label.new()
		leaf.text = _current_machine.machine_name
		_breadcrumb.add_child(leaf)


# ------------------------------------------------------------------ views ---

func show_overview() -> void:
	_current_machine = null
	_clear_view_host()
	if _behavior == null:
		return
	var script := load(OVERVIEW_SCRIPT) as GDScript
	_overview = script.new()
	_view_host.add_child(_overview)
	_overview.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overview.setup(_behavior, self)
	_overview.dive_requested.connect(show_machine)
	_refresh_chrome()


func show_machine(m: SubStateMachine) -> void:
	if m == null or _behavior == null:
		return
	_stop_preview()
	_current_machine = m
	_clear_view_host()
	if _grouped_mode:
		var gscript := load(GROUPED_SCRIPT) as GDScript
		_grouped = gscript.new()
		_view_host.add_child(_grouped)
		_grouped.set_anchors_preset(Control.PRESET_FULL_RECT)
		_grouped.setup(m, self)
	else:
		var script := load(GRAPH_SCRIPT) as GDScript
		_graph = script.new()
		_view_host.add_child(_graph)
		_graph.set_anchors_preset(Control.PRESET_FULL_RECT)
		_graph.setup(m, self)
	edit_resource(m)
	_refresh_chrome()


func _on_grouped_toggled(on: bool) -> void:
	_grouped_mode = on
	if _current_machine != null and _behavior != null:
		show_machine(_current_machine)


## Leave the grouped view and focus a state in the flat graph
## (double-click in the grouped detail graph).
func dive_to_state(m: SubStateMachine, s: FrameState) -> void:
	_grouped_mode = false
	if _grouped_button != null:
		_grouped_button.set_pressed_no_signal(false)
	show_machine(m)
	if s != null and is_instance_valid(_graph) and _graph.has_method("focus_state"):
		_graph.focus_state(s)
		edit_resource(s)


func current_graph() -> Control:
	return _graph


func is_snap_enabled() -> bool:
	return _snap_button.button_pressed


func _on_units_toggled(on: bool) -> void:
	use_seconds = on
	_units_button.text = "sec" if on else "frames"
	if is_instance_valid(_graph) and _graph.has_method("refresh"):
		_graph.refresh()
	if is_instance_valid(_grouped) and _grouped.has_method("refresh"):
		_grouped.refresh()
	if is_instance_valid(_overview) and _overview.has_method("refresh"):
		_overview.refresh()


# ------------------------------------------------------------------ dirty ---

func mark_dirty() -> void:
	_dirty = true
	_refresh_chrome()


func _on_inspector_property_edited(_prop: String) -> void:
	# The built-in inspector handles undo itself; update labels in place
	# (a full rebuild here would destroy the node being edited).
	mark_dirty()
	if is_instance_valid(_graph) and _graph.has_method("update_labels"):
		_graph.update_labels()
	if is_instance_valid(_grouped) and _grouped.has_method("update_labels"):
		_grouped.update_labels()
	if is_instance_valid(_overview) and _overview.has_method("refresh"):
		_overview.refresh()
	# Edits (incl. renames) are picked up by the preview step, which
	# re-serializes and reloads the Rust player when the JSON changed.


# ------------------------------------------------------------------ selection ---

func edit_resource(res: Resource) -> void:
	if _ei != null and res != null:
		_ei.get_inspector().edit(res)


# ------------------------------------------------------------------ undo helpers ---

func do_add_state(machine: SubStateMachine, pos: Vector2) -> void:
	var s := FrameState.new()
	s.state_name = _unique_state_name(machine, "State")
	s.duration_frames = 1
	s.editor_position = pos
	_undo_redo.create_action("Add State")
	_undo_redo.add_do_method(self, "_do_add_state", machine, s)
	_undo_redo.add_undo_method(self, "_undo_add_state", machine, s)
	_undo_redo.commit_action()
	mark_dirty()
	_after_structure_change()
	edit_resource(s)


func _do_add_state(machine: SubStateMachine, s: FrameState) -> void:
	machine.states.append(s)
	if machine.entry_state == null:
		machine.entry_state = s


func _undo_add_state(machine: SubStateMachine, s: FrameState) -> void:
	machine.states.erase(s)
	for other in machine.states:
		for row in other.transitions:
			if row.target_state_name == s.state_name:
				row.target_state_name = &""
	if machine.entry_state == s:
		machine.entry_state = machine.states[0] if not machine.states.is_empty() else null


func do_delete_states(machine: SubStateMachine, states: Array) -> void:
	if states.is_empty():
		return
	var old_states := machine.states.duplicate()
	var old_entry: FrameState = machine.entry_state
	var old_targets := {}
	for s in machine.states:
		for row in s.transitions:
			old_targets[row] = row.target_state_name
	_undo_redo.create_action("Delete States")
	_undo_redo.add_do_method(self, "_do_delete_states", machine, states)
	_undo_redo.add_undo_method(self, "_undo_delete_states", machine, old_states, old_entry, old_targets)
	_undo_redo.commit_action()
	mark_dirty()
	_after_structure_change()


func _do_delete_states(machine: SubStateMachine, states: Array) -> void:
	var dead_names := {}
	for s in states:
		dead_names[(s as FrameState).state_name] = true
	for s in states:
		machine.states.erase(s)
	for other in machine.states:
		for row in other.transitions:
			if dead_names.has(row.target_state_name):
				row.target_state_name = &""
	if states.has(machine.entry_state):
		machine.entry_state = machine.states[0] if not machine.states.is_empty() else null


func _undo_delete_states(machine: SubStateMachine, old_states: Array, old_entry: FrameState, old_targets: Dictionary) -> void:
	var typed: Array[FrameState] = []
	typed.assign(old_states)
	machine.states = typed
	machine.entry_state = old_entry
	for row in old_targets.keys():
		(row as FFTransition).target_state_name = old_targets[row]


func do_connect_row(row: FFTransition, target: FrameState) -> void:
	var old: StringName = row.target_state_name
	var new_name: StringName = target.state_name if target != null else &""
	_undo_redo.create_action("Connect Transition")
	_undo_redo.add_do_property(row, "target_state_name", new_name)
	_undo_redo.add_undo_property(row, "target_state_name", old)
	_undo_redo.commit_action()
	mark_dirty()
	_after_structure_change()


func do_add_row(state: FrameState) -> void:
	var row := FFTransition.new()
	var cond := FFCondition.new()
	cond.type = FFCondition.Type.ON_COMPLETE
	row.condition = cond
	_undo_redo.create_action("Add Transition Row")
	_undo_redo.add_do_method(self, "_do_add_row", state, row)
	_undo_redo.add_undo_method(self, "_undo_add_row", state, row)
	_undo_redo.commit_action()
	mark_dirty()
	_after_structure_change()
	edit_resource(row)


func _do_add_row(state: FrameState, row: FFTransition) -> void:
	state.transitions.append(row)


func _undo_add_row(state: FrameState, row: FFTransition) -> void:
	state.transitions.erase(row)


func do_delete_row(state: FrameState, idx: int) -> void:
	if idx < 0 or idx >= state.transitions.size():
		return
	var row: FFTransition = state.transitions[idx]
	_undo_redo.create_action("Delete Transition Row")
	_undo_redo.add_do_method(self, "_undo_add_row", state, row)
	_undo_redo.add_undo_method(self, "_do_insert_row", state, row, idx)
	_undo_redo.commit_action()
	mark_dirty()
	_after_structure_change()


func _do_insert_row(state: FrameState, row: FFTransition, idx: int) -> void:
	state.transitions.insert(mini(idx, state.transitions.size()), row)


func do_move_row(state: FrameState, from_idx: int, to_idx: int) -> void:
	if from_idx == to_idx:
		return
	var n := state.transitions.size()
	if from_idx < 0 or from_idx >= n or to_idx < 0 or to_idx >= n:
		return
	_undo_redo.create_action("Reorder Transition Row")
	_undo_redo.add_do_method(self, "_do_move_row", state, from_idx, to_idx)
	_undo_redo.add_undo_method(self, "_do_move_row", state, to_idx, from_idx)
	_undo_redo.commit_action()
	mark_dirty()
	_after_structure_change()


func _do_move_row(state: FrameState, from_idx: int, to_idx: int) -> void:
	var row: FFTransition = state.transitions[from_idx]
	state.transitions.remove_at(from_idx)
	state.transitions.insert(to_idx, row)


func _unique_state_name(machine: SubStateMachine, base: String) -> String:
	var names := {}
	for s in machine.states:
		if s != null:
			names[s.state_name] = true
	if not names.has(base):
		return base
	var i := 2
	while names.has("%s%d" % [base, i]):
		i += 1
	return "%s%d" % [base, i]


func _after_structure_change() -> void:
	_stop_preview()
	if is_instance_valid(_graph) and _graph.has_method("refresh"):
		_graph.refresh()
	if is_instance_valid(_grouped) and _grouped.has_method("refresh"):
		_grouped.refresh()
	if is_instance_valid(_overview) and _overview.has_method("refresh"):
		_overview.refresh()
	_refresh_chrome()


# ------------------------------------------------------------------ toolbar actions ---

func _on_add_state() -> void:
	if _current_machine == null:
		return
	var center := Vector2(60, 60)
	if is_instance_valid(_graph) and _graph.has_method("canvas_center"):
		center = _graph.canvas_center()
	do_add_state(_current_machine, center)


func _on_add_comment() -> void:
	if _current_machine == null:
		return
	var c := FFComment.new()
	c.title = "Comment"
	var center := Vector2(60, 60)
	if is_instance_valid(_graph) and _graph.has_method("canvas_center"):
		center = _graph.canvas_center()
	c.position = center
	_undo_redo.create_action("Add Comment")
	_undo_redo.add_do_method(self, "_do_add_comment", _current_machine, c)
	_undo_redo.add_undo_method(self, "_undo_add_comment", _current_machine, c)
	_undo_redo.commit_action()
	mark_dirty()
	_after_structure_change()


func _do_add_comment(machine: SubStateMachine, c: FFComment) -> void:
	machine.editor_comments.append(c)


func _undo_add_comment(machine: SubStateMachine, c: FFComment) -> void:
	machine.editor_comments.erase(c)


# ------------------------------------------------------------------ preview ---

func _on_preview_toggled(on: bool) -> void:
	if on:
		_start_preview()
	else:
		_stop_preview()


## The preview drives the Rust GDExtension BehaviorPlayer (the one
## evaluator — all logic lives in the Rust core). The editor serializes
## the current behavior to a scratch JSON and load_behavior()s it.
const PREVIEW_PATH := "user://frameforge_preview.json"

var _preview_json := ""


func _start_preview() -> void:
	if _behavior == null:
		return
	_stop_preview()
	_preview_player = BehaviorPlayer.new()
	_preview_player.auto_step = false
	add_child(_preview_player)
	_preview_player.state_entered.connect(_on_preview_state_changed)
	_preview_player.state_exited.connect(_on_preview_state_changed)
	_preview_player.behavior_changed.connect(_on_preview_behavior_changed)
	_preview_player.event_fired.connect(_on_preview_event)
	_preview_json = ""
	_sync_preview_behavior()
	_ensure_monitor()
	_monitor.clear()
	_previewing = true
	_preview_timer.start()


## Re-serialize + reload when the behavior's JSON changed (edits made
## during preview restart the sim on the new content).
func _sync_preview_behavior() -> void:
	if not is_instance_valid(_preview_player) or _behavior == null:
		return
	var json := JSON.stringify(BehaviorJSON.behavior_to_dict(_behavior), "\t")
	if json == _preview_json:
		return
	_preview_json = json
	var f := FileAccess.open(PREVIEW_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("FrameForge preview: cannot write " + PREVIEW_PATH)
		return
	f.store_string(json)
	f.close()
	if not _preview_player.load_behavior(PREVIEW_PATH):
		push_warning("FrameForge preview: Rust player rejected the behavior JSON")


func _on_preview_behavior_changed(_old: String, _new: String) -> void:
	_on_preview_state_changed("", "", "")


func _stop_preview() -> void:
	_previewing = false
	if _preview_timer != null:
		_preview_timer.stop()
	if is_instance_valid(_preview_player):
		_preview_player.queue_free()
	_preview_player = null
	if is_instance_valid(_graph) and _graph.has_method("clear_highlight"):
		_graph.clear_highlight()
	if is_instance_valid(_grouped) and _grouped.has_method("clear_highlight"):
		_grouped.clear_highlight()


func _on_preview_step() -> void:
	if not _previewing or not is_instance_valid(_preview_player):
		return
	_sync_preview_behavior()
	for i in 6:  # 6 ticks per 0.1s ≈ 60 Hz
		_preview_player.tick()
	_on_preview_state_changed("", "", "")
	_update_monitor_params()


func _on_preview_state_changed(_a: String, _b: String, _c: String) -> void:
	if is_instance_valid(_graph) and _graph.has_method("highlight_active"):
		_graph.highlight_active(_preview_player)
	if is_instance_valid(_grouped) and _grouped.has_method("highlight_active"):
		_grouped.highlight_active(_preview_player)


func _on_preview_event(event_name: String) -> void:
	if _monitor != null:
		_monitor.log_event(event_name)


func _update_monitor_params() -> void:
	if _monitor == null or _behavior == null or not is_instance_valid(_preview_player):
		return
	var d := {}
	for p in _behavior.parameters:
		if p != null:
			d[p.name] = _preview_player.get_param(p.name)
	_monitor.set_params(d)


func _ensure_monitor() -> void:
	if _monitor != null:
		return
	var script := load(MONITOR_SCRIPT) as GDScript
	_monitor = script.new()
	add_child(_monitor)
	_monitor.visible = true


# ------------------------------------------------------------------ validation ---

func validate() -> void:
	if _behavior == null:
		return
	_ensure_validation_panel()
	var validator := load(VALIDATOR_SCRIPT) as GDScript
	var issues: Array = validator.validate_behavior(_behavior)
	_validation_panel.show_issues(issues)


func _ensure_validation_panel() -> void:
	if _validation_panel != null:
		return
	var script := load(VALIDATION_SCRIPT) as GDScript
	_validation_panel = script.new()
	add_child(_validation_panel)
	_validation_panel.setup(self)
	_validation_panel.visible = false


func goto_issue(issue: Dictionary) -> void:
	var m: SubStateMachine = issue.get("machine")
	var s: FrameState = issue.get("state")
	if _grouped_mode:
		_grouped_mode = false
		if _grouped_button != null:
			_grouped_button.set_pressed_no_signal(false)
		if m != null:
			show_machine(m)
	if m != null and m != _current_machine:
		show_machine(m)
	if s != null and is_instance_valid(_graph) and _graph.has_method("focus_state"):
		_graph.focus_state(s)
