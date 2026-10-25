@tool
extends VBoxContainer
## Validation results panel: lists FFValidator issues; click an item to
## jump to the offending state/machine on the canvas.

var _editor: Control = null
var _list: ItemList
var _issues: Array = []
var _title: Label


func setup(editor: Control) -> void:
	_editor = editor
	custom_minimum_size = Vector2(0, 130)
	_title = Label.new()
	add_child(_title)
	_list = ItemList.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.item_selected.connect(_on_item_selected)
	add_child(_list)


func show_issues(issues: Array) -> void:
	_issues = issues
	_list.clear()
	var errors := 0
	for i in issues:
		if i["severity"] == "error":
			errors += 1
		var prefix := "ERROR" if i["severity"] == "error" else "WARN"
		var where := ""
		var m: SubStateMachine = i["machine"]
		var s: FrameState = i["state"]
		if m != null:
			where = m.machine_name
		if s != null:
			where += ("/" if not where.is_empty() else "") + s.state_name
		if where.is_empty():
			where = "behavior"
		_list.add_item("%s [%s] %s" % [prefix, where, i["message"]])
	_title.text = "Validation: %d errors, %d warnings" % [errors, issues.size() - errors]
	visible = not issues.is_empty()


func _on_item_selected(index: int) -> void:
	if _editor != null and index >= 0 and index < _issues.size():
		_editor.goto_issue(_issues[index])
