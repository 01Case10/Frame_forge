extends Node3D
## Side-by-side video: plays an exit-gate scenario through BehaviorPlayer.
## Usage: godot --path . --write-movie out.avi --fixed-fps 30
##        res://scenario_player.tscn -- --scenario <path.json> --behavior <name>
## Behavior JSONs live in rust/behaviors/. Ticks at 60 Hz; scenario inputs
## are 30 Hz sim frames, so each input frame = 2 ticks (tpf from --tpf).

var _scenario := {}
var _segments: Array = []
var _seg_idx := 0
var _seg_frame := 0
var _tpf := 1
var _total_frames := 0
var _frame := 0

var _player: BehaviorPlayer


func _parse_args() -> Dictionary:
	var out := {}
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		if args[i] == "--scenario" and i + 1 < args.size():
			out["scenario"] = args[i + 1]
			i += 2
		elif args[i] == "--behavior" and i + 1 < args.size():
			out["behavior"] = args[i + 1]
			i += 2
		elif args[i] == "--tpf" and i + 1 < args.size():
			out["tpf"] = int(args[i + 1])
			i += 2
		else:
			i += 1
	return out


func _ready() -> void:
	Engine.physics_ticks_per_second = 30
	for a in ["ff_left", "ff_right", "ff_fwd", "ff_back", "ff_jump", "ff_attack", "ff_crouch"]:
		if not InputMap.has_action(a):
			InputMap.add_action(a)
	var args := _parse_args()
	var sc_path: String = args.get("scenario", "")
	var bh_name: String = args.get("behavior", "")
	_tpf = int(args.get("tpf", 1))
	if sc_path.is_empty() or bh_name.is_empty():
		push_error("scenario_player: --scenario and --behavior required")
		get_tree().quit(1)
		return
	_scenario = JSON.parse_string(FileAccess.get_file_as_string(sc_path))
	_segments = _scenario["inputs"]
	for seg in _segments:
		_total_frames += int(seg["frames"])
	# Build collision from scenario geometry.
	_build_collision()
	# Player.
	_player = BehaviorPlayer.new()
	_player.auto_step = false
	var ok := _player.load_behavior("res://rust/behaviors/" + bh_name)
	add_child(_player)
	# Visual capsule.
	var mi := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.4
	cap.height = 1.6
	mi.mesh = cap
	_player.add_child(mi)
	print("scenario_player: load ", bh_name, " ok=", ok)
	var start: Array = _scenario["start"]["pos"]
	_player.position = Vector3(float(start[0]), float(start[1]), float(start[2])) * 0.01
	$HUD/MoveLabel.text = _scenario["id"] + " (FrameForge)"
	print("scenario_player: ", _scenario["id"], " frames=", _total_frames, " tpf=", _tpf)


func _build_collision() -> void:
	var level := StaticBody3D.new()
	level.name = "Level"
	add_child(level)
	for g in _scenario["geometry"]:
		var mn: Array = g["min"]
		var mx: Array = g["max"]
		var min_m := Vector3(float(mn[0]), float(mn[1]), float(mn[2])) * 0.01
		var max_m := Vector3(float(mx[0]), float(mx[1]), float(mx[2])) * 0.01
		var size := max_m - min_m
		var center := (min_m + max_m) * 0.5
		var cs := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = size
		cs.shape = shape
		var body := StaticBody3D.new()
		body.position = center
		body.add_child(cs)
		level.add_child(body)
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = size
		mi.mesh = bm
		mi.position = center
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.35, 0.45, 0.35)
		mi.material_override = mat
		add_child(mi)


func _set_axis(neg_action: String, pos_action: String, value: float) -> void:
	# Mirrors run_gate.gd: stick maps to actions.
	if value > 0.01:
		Input.action_press(pos_action, value)
		Input.action_release(neg_action)
	elif value < -0.01:
		Input.action_press(neg_action, -value)
		Input.action_release(pos_action)
	else:
		Input.action_release(pos_action)
		Input.action_release(neg_action)


func _physics_process(_delta: float) -> void:
	if _frame >= _total_frames:
		print("scenario_player: done")
		get_tree().quit(0)
		return
	# Advance to the current input segment.
	while _seg_idx < _segments.size() and _seg_frame >= int(_segments[_seg_idx]["frames"]):
		_seg_idx += 1
		_seg_frame = 0
	if _seg_idx < _segments.size():
		var seg: Dictionary = _segments[_seg_idx]
		var stick: Array = seg["stick"]
		var sx := float(stick[0]) / 80.0
		var sy := float(stick[1]) / 80.0
		# run_gate mapping (with x-swap): stick_x+ -> ff_left.
		_set_axis("ff_right", "ff_left", sx)
		_set_axis("ff_back", "ff_fwd", sy)
		var buttons := int(seg["buttons"])
		if buttons & 1:
			Input.action_press("ff_jump")
		else:
			Input.action_release("ff_jump")
		if buttons & 2:
			Input.action_press("ff_attack")
		else:
			Input.action_release("ff_attack")
		if buttons & 4:
			Input.action_press("ff_crouch")
		else:
			Input.action_release("ff_crouch")
	_seg_frame += 1
	_frame += 1
	for i in _tpf:
		_player.tick()
	# Camera follows.
	var rig: Node3D = $CameraRig
	var target := _player.global_position + Vector3(0, 1.2, 0)
	rig.global_position = rig.global_position.lerp(target, 0.2)
