@tool
extends EditorPlugin
## FrameForge editor plugin: registers the main-screen behavior editor.

const EDITOR_SCRIPT_PATH := "res://addons/frameforge/editor/behavior_editor.gd"

var _view: Control = null


func _enter_tree() -> void:
	var script := load(EDITOR_SCRIPT_PATH) as GDScript
	if script == null:
		push_error("FrameForge: could not load behavior_editor.gd")
		return
	_view = script.new() as Control
	if _view == null:
		push_error("FrameForge: behavior_editor.gd is not a Control")
		return
	_view.setup(get_editor_interface(), get_undo_redo())
	_view.name = "FrameForge"
	get_editor_interface().get_editor_main_screen().add_child(_view)
	_make_visible(false)


func _exit_tree() -> void:
	if is_instance_valid(_view):
		_view.queue_free()
		_view = null


func _has_main_screen() -> bool:
	return true


func _make_visible(visible: bool) -> void:
	if is_instance_valid(_view):
		_view.visible = visible


func _get_plugin_name() -> String:
	return "FrameForge"


func _get_plugin_icon() -> Texture2D:
	return get_editor_interface().get_base_control().get_theme_icon("GraphEdit", "EditorIcons")
