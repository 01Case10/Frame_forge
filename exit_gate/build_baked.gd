extends SceneTree
## Step 2 of the exit-gate baker: baked trajectory JSON -> 60Hz .tres chain.
## Each sim frame becomes one 2-frame state (even easing); the 2-tick total
## equals the sim displacement exactly, so 30Hz sample points match the
## oracle to float precision.
## Usage: godot --headless --path . --script res://exit_gate/build_baked.gd
##        -- --in baked.json --out chain.tres --name BackflipBaked

const SIM_TO_M := 0.01  # 1 sim unit (cm) = 0.01 Godot meters


func _init() -> void:
	var args := _parse_args()
	var in_path: String = args.get("--in", "")
	var out_path: String = args.get("--out", "")
	var bname: String = args.get("--name", "Baked")
	if in_path.is_empty() or out_path.is_empty():
		print("usage: -- --in baked.json --out chain.tres [--name X]")
		quit(1)
		return
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(in_path))
	var disps: Array = data["displacements"]

	var bh := FrameBehavior.new()
	bh.behavior_name = bname
	var m := SubStateMachine.new()
	m.machine_name = "Baked"
	var states: Array[FrameState] = []
	var n: int = disps.size()
	for i in n:
		var d: Array = disps[i]
		var v := Vector3(float(d[0]), float(d[1]), float(d[2])) * SIM_TO_M
		var s := FrameState.new()
		s.state_name = "f%d" % i
		s.duration_frames = 2
		s.displacement = v.length()
		s.direction = v.normalized() if v.length_squared() > 1e-18 else Vector3.ZERO
		s.easing = _linear_curve()
		states.append(s)
	for i in n:
		var row := FFTransition.new()
		var c := FFCondition.new()
		c.type = FFCondition.Type.ON_COMPLETE
		row.condition = c
		var target: FrameState = states[mini(i + 1, n - 1)]
		row.target_state_name = target.state_name
		states[i].transitions = [row]
	m.states = states
	m.entry_state = states[0]
	bh.sub_machines = [m]
	var err := ResourceSaver.save(bh, out_path)
	print("saved %d-state chain -> %s (%s)" % [n, out_path, err])
	quit(0 if err == OK else 1)


func _linear_curve() -> Curve:
	var c := Curve.new()
	c.add_point(Vector2(0, 0))
	c.add_point(Vector2(1, 1))
	c.set_point_left_tangent(1, 1.0)
	c.set_point_right_tangent(0, 1.0)
	return c


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
