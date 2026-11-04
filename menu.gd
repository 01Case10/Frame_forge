extends Control
## FrameForge demo menu (the project's main scene).
## Lists the exit-gate scenario playbacks; picking one sets SceneTree metas
## consumed by scenario_player.gd, then loads res://scenario_player.tscn.

const SCENARIO_DIR := "res://exit_gate/scenarios/"
const PLAYER_SCENE := "res://scenario_player.tscn"
const PLAYGROUND_SCENE := "res://playground.tscn"

## Free-play movesets: label and the SceneTree meta value playground.gd reads.
const MOVESETS := [
	{ "label": "Playground: Mario 64", "key": "sm64" },
	{ "label": "Playground: Odyssey", "key": "smo" },
	{ "label": "Playground: Galaxy", "key": "smg" },
]

## label: button text; scenario: exit_gate/scenarios/<id>.json;
## behavior: rust/behaviors/<file>; tpf: scenario sim-frames per player tick.
## (behavior/tpf pairings match rust/release-gate.sh)
const DEMOS: Array = [
	{ "label": "Walk straight", "scenario": "walk_straight", "behavior": "walk.json", "tpf": 1 },
	{ "label": "Walk release", "scenario": "walk_release", "behavior": "walk.json", "tpf": 1 },
	{ "label": "Walk turn", "scenario": "walk_turn", "behavior": "walk.json", "tpf": 1 },
	{ "label": "Walk chain (90 deg turn)", "scenario": "walk_forward_90f", "behavior": "walk_chain.json", "tpf": 2 },
	{ "label": "Jump (neutral, tap)", "scenario": "jump_neutral", "behavior": "move.json", "tpf": 1 },
	{ "label": "Jump (neutral, held)", "scenario": "jump_neutral_held", "behavior": "move.json", "tpf": 1 },
	{ "label": "Jump forward", "scenario": "jump_forward_held", "behavior": "jump_fwd.json", "tpf": 1 },
	{ "label": "Double jump", "scenario": "double_jump", "behavior": "double_jump.json", "tpf": 1 },
	{ "label": "Ground pound", "scenario": "ground_pound", "behavior": "ground_pound.json", "tpf": 1 },
	{ "label": "Long jump", "scenario": "long_jump", "behavior": "long_jump.json", "tpf": 1 },
	{ "label": "Triple jump", "scenario": "triple_jump", "behavior": "triple_jump_baked.json", "tpf": 2 },
	{ "label": "Triple jump (variant 2)", "scenario": "triple_jump2", "behavior": "triple_jump_baked.json", "tpf": 2 },
	{ "label": "Wall kick", "scenario": "wall_kick", "behavior": "wall_kick_chain.json", "tpf": 2 },
]


func _ready() -> void:
	if ClassDB.class_exists("BehaviorPlayer"):
		%Status.text = "BehaviorPlayer extension loaded - demos ready."
	else:
		%Status.text = "BehaviorPlayer extension NOT found - build it from rust/ first."
	for d in DEMOS:
		var b := Button.new()
		b.text = str(d["label"])
		b.pressed.connect(_play.bind(d))
		%DemoList.add_child(b)
	for m in MOVESETS:
		var fb := Button.new()
		fb.text = str(m["label"])
		fb.pressed.connect(_play_free.bind(str(m["key"])))
		%FreeBox.add_child(fb)
	%Quit.pressed.connect(_on_quit)


func _play(d: Dictionary) -> void:
	var tree := get_tree()
	tree.set_meta("ff_scenario", SCENARIO_DIR + str(d["scenario"]) + ".json")
	tree.set_meta("ff_behavior", str(d["behavior"]))
	tree.set_meta("ff_tpf", int(d["tpf"]))
	tree.set_meta("ff_from_menu", true)
	tree.change_scene_to_file(PLAYER_SCENE)


func _play_free(key: String) -> void:
	var tree := get_tree()
	tree.set_meta("ff_moveset", key)
	tree.change_scene_to_file(PLAYGROUND_SCENE)


func _on_quit() -> void:
	get_tree().quit()
