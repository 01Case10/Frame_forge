extends Node
## Exit-gate differential harness: replays a stepkit oracle trajectory
## against a FrameForge behavior and reports position error.
##
## Usage: godot --headless --path . res://exit_gate/run_gate.tscn --
##        --behavior <behavior.json> --oracle <trace.csv>
##        [--scenario-json <scenario.json>] [--name Label]
##
## Behaviors are JSON (rust/behaviors/, or export the .tres set with
## exit_gate/export_json.gd). The player is the Rust GDExtension
## BehaviorPlayer — the same evaluator the editor preview uses.
##
## --scenario-json builds the scenario's boxes as statics; without it the
## world is empty (correct for baked chains, whose displacements already
## encode collision). Samples the player every 2 ticks (60Hz -> 30Hz) and
## compares against oracle frames. Tolerances (cm): mean < 0.5, max < 2.0,
## final < 1.0.

const SIM_TO_M := 0.01
const TICKS_PER_FRAME := 25
const MEAN_TOL := 0.5
const MAX_TOL := 2.0
const FINAL_TOL := 1.0

var _player: BehaviorPlayer
var _oracle: Array[Vector3] = []  # meters
var _inputs: Array = []  # per sim frame: [stick_x, stick_y, buttons]
var _samples: Array[Vector3] = []
var _ticks_done := 0
var _ticks_total := 0
var _label := ""
## Sim frames per FF tick inverse: baked chains use 2 (each sim frame is a
## 2-frame state); interactive behaviors use 1 (1 tick = 1 sim frame).
var _ticks_per_frame := 2


func _ready() -> void:
	var args := _parse_args()
	_label = args.get("--name", "gate")
	var bpath: String = args.get("--behavior", "")
	var opath: String = args.get("--oracle", "")
	if bpath.is_empty() or opath.is_empty():
		print("usage: -- --behavior <json> --oracle <csv> [--scenario-json <json>]")
		get_tree().quit(1)
		return
	_ensure_input_actions()
	_load_oracle(opath)
	_ticks_per_frame = int(args.get("--ticks-per-frame", "2"))
	var scenario_json: String = args.get("--scenario-json", "")
	if not scenario_json.is_empty():
		_build_arena(scenario_json)
	_player = BehaviorPlayer.new()
	add_child(_player)
	_player.global_position = _oracle[0]
	_player.auto_step = false
	if not _player.load_behavior(bpath):
		print("run_gate: Rust player failed to load ", bpath)
		get_tree().quit(1)
		return
	_ticks_total = (_oracle.size() - 1) * _ticks_per_frame


## Interactive behaviors read these actions (see INPUT mapping below).
func _ensure_input_actions() -> void:
	for a in ["ff_left", "ff_right", "ff_fwd", "ff_back", "ff_jump", "ff_crouch", "ff_attack"]:
		if not InputMap.has_action(a):
			InputMap.add_action(a)


## Drive the FF InputMap from the oracle's per-frame stick/buttons.
## FF tick t sees sim frame i=t/_ticks_per_frame's input.
func _replay_input(tick: int) -> void:
	var i: int = mini(tick / _ticks_per_frame, _inputs.size() - 1)
	if i < 0:
		return
	var sx: float = _inputs[i][0]
	var sy: float = _inputs[i][1]
	var buttons: int = _inputs[i][2]
	_set_axis("ff_right", "ff_left", sx / 80.0)  # sim stick_x+ -> -X world; FF ff_right -> +X
	_set_axis("ff_fwd", "ff_back", sy / 80.0)
	_set_button("ff_jump", buttons & 0x1)
	_set_button("ff_attack", buttons & 0x2)
	_set_button("ff_crouch", buttons & 0x4)


## pair = (neg_action, pos_action); v>0 presses pos, v<0 presses neg.
## NOTE: sim stick_y+ means +Z world, so ff_back carries +sy.
func _set_axis(neg: String, pos: String, v: float) -> void:
	if v > 0.05:
		Input.action_release(neg)
		Input.action_press(pos, clampf(v, 0.0, 1.0))
	elif v < -0.05:
		Input.action_press(neg, clampf(-v, 0.0, 1.0))
		Input.action_release(pos)
	else:
		Input.action_release(neg)
		Input.action_release(pos)


func _set_button(a: String, held: int) -> void:
	if held:
		Input.action_press(a)
	else:
		Input.action_release(a)


func _physics_process(_delta: float) -> void:
	if _player == null or _ticks_total <= 0:
		return
	var n: int = mini(TICKS_PER_FRAME, _ticks_total - _ticks_done)
	for i in n:
		if _ticks_done % _ticks_per_frame == 0:
			_samples.append(_player.global_position)
		_replay_input(_ticks_done)
		_player.tick()
		_ticks_done += 1
		if _ticks_done >= _ticks_total:
			_samples.append(_player.global_position)
			break
	if _ticks_done >= _ticks_total:
		_finish()


func _finish() -> void:
	var errs: Array[float] = []
	var n: int = mini(_samples.size(), _oracle.size())
	for k in n:
		errs.append((_samples[k] - _oracle[k]).length() * 100.0)  # cm
	var mean := 0.0
	var mx := 0.0
	for e in errs:
		mean += e
		mx = maxf(mx, e)
	mean /= maxf(1.0, float(errs.size()))
	var final := errs[errs.size() - 1] if not errs.is_empty() else 999.0
	var ok := mean < MEAN_TOL and mx < MAX_TOL and final < FINAL_TOL
	print("==== %s: frames=%d mean=%.4fcm max=%.4fcm final=%.4fcm -> %s ====" % [
		_label, n, mean, mx, final, "PASS" if ok else "FAIL"])
	get_tree().quit(0 if ok else 1)


func _load_oracle(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	var header := f.get_csv_line()
	var ix := header.find("pos_x")
	var iy := header.find("pos_y")
	var iz := header.find("pos_z")
	var sx := header.find("stick_x")
	var sy := header.find("stick_y")
	var bt := header.find("buttons")
	while not f.eof_reached():
		var line := f.get_csv_line()
		if line.size() <= maxi(ix, maxi(iy, iz)):
			continue
		_oracle.append(Vector3(float(line[ix]), float(line[iy]), float(line[iz])) * SIM_TO_M)
		_inputs.append([float(line[sx]), float(line[sy]), int(line[bt])])


func _build_arena(json_path: String) -> void:
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(json_path))
	for g in data.get("geometry", []):
		var mn: Array = g["min"]
		var mx: Array = g["max"]
		var a := Vector3(float(mn[0]), float(mn[1]), float(mn[2])) * SIM_TO_M
		var b := Vector3(float(mx[0]), float(mx[1]), float(mx[2])) * SIM_TO_M
		var body := StaticBody3D.new()
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = b - a
		shape.shape = box
		body.add_child(shape)
		body.position = (a + b) * 0.5
		add_child(body)


func _parse_args() -> Dictionary:
	var out := {}
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		var a: String = args[i]
		if a.begins_with("--") and i + 1 < args.size() and not args[i + 1].begins_with("--"):
			out[a] = args[i + 1]
			i += 2
		else:
			i += 1
	return out
