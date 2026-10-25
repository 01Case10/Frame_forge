@tool
extends VBoxContainer
## Preview bottom panel: event log + live blackboard parameters.

var _log: RichTextLabel
var _params_label: Label
var _count := 0


func _ready() -> void:
	custom_minimum_size = Vector2(0, 140)
	var title := Label.new()
	title.text = "Event Monitor"
	add_child(title)
	_log = RichTextLabel.new()
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.scroll_following = true
	add_child(_log)
	_params_label = Label.new()
	_params_label.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0))
	# The params line lists every blackboard parameter on one logical
	# line; without wrapping, the label's minimum width is the whole
	# string (thousands of px on SMO) and inflates the editor layout.
	_params_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_params_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_params_label)


func log_event(event_name: String) -> void:
	_count += 1
	_log.append_text("[%d] event \"%s\"\n" % [_count, event_name])


func set_params(d: Dictionary) -> void:
	var parts: Array[String] = []
	for k in d.keys():
		parts.append("%s=%s" % [str(k), str(d[k])])
	_params_label.text = "params: " + ", ".join(parts)


func clear() -> void:
	_count = 0
	_log.clear()
	_params_label.text = ""
