@tool
extends VBoxContainer
## Behavior overview: one collapsed container per sub-machine
## (name, state count, total frames) with a chevron to dive in.

signal dive_requested(machine: SubStateMachine)

var _behavior: FrameBehavior = null
var _editor: Control = null
var _list: VBoxContainer


func setup(behavior: FrameBehavior, editor: Control) -> void:
	_behavior = behavior
	_editor = editor
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 8)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list)
	add_child(scroll)
	refresh()


func refresh() -> void:
	for c in _list.get_children():
		c.queue_free()
	if _behavior == null:
		return
	for m in _behavior.sub_machines:
		if m == null:
			continue
		_list.add_child(_make_container(m))
	# Behavior-level transitions summary (edited in the inspector).
	var note := Label.new()
	note.text = "Behavior transitions: %d (edit via the Inspector with the behavior selected)" % _behavior.behavior_transitions.size()
	note.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	_list.add_child(note)


func _make_container(m: SubStateMachine) -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(420, 0)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 10)
	panel.add_child(hb)

	var chev := Button.new()
	chev.text = "›"
	chev.focus_mode = Control.FOCUS_NONE
	chev.pressed.connect(func() -> void: dive_requested.emit(m))
	hb.add_child(chev)

	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(vb)

	var title := Label.new()
	title.text = m.machine_name
	vb.add_child(title)

	var total_frames := 0
	for s in m.states:
		if s != null:
			total_frames += maxi(1, s.duration_frames)
	var sub := Label.new()
	var time_str := "%df" % total_frames
	if _editor != null and bool(_editor.get("use_seconds")):
		time_str = "%.2fs" % (total_frames / 60.0)
	sub.text = "%d states, %s" % [m.states.size(), time_str]
	sub.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	vb.add_child(sub)

	var open := Button.new()
	open.text = "Open"
	open.focus_mode = Control.FOCUS_NONE
	open.pressed.connect(func() -> void: dive_requested.emit(m))
	hb.add_child(open)
	return panel
