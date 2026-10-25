extends SceneTree
## Phase 5 headless tests: FFValidator diagnostics.
## Reports PASS/FAIL; exits with the failure count as the exit code.

var _passes := 0
var _failures: Array[String] = []


func _init() -> void:
	_run_all()
	print("==== Phase 5: %d passed, %d failed ====" % [_passes, _failures.size()])
	for f in _failures:
		print("FAIL: ", f)
	print("ALL GREEN" if _failures.is_empty() else "FAILURES PRESENT")
	quit(_failures.size())


func _check(cond: bool, name: String) -> void:
	if cond:
		_passes += 1
	else:
		_failures.append(name)
		print("FAIL: ", name)


func _issues_with(issues: Array, severity: String, substr: String) -> Array:
	var out := []
	for i in issues:
		if i["severity"] == severity and substr in i["message"]:
			out.append(i)
	return out


# ------------------------------------------------------------------ builders ---

func _mk_state(sname: String, dur := 10, disp := 1.0, dir := Vector3.RIGHT) -> FrameState:
	var s := FrameState.new()
	s.state_name = sname
	s.duration_frames = dur
	s.displacement = disp
	s.direction = dir
	return s


func _mk_row(target: FrameState, ctype := FFCondition.Type.ON_COMPLETE) -> FFTransition:
	var row := FFTransition.new()
	var c := FFCondition.new()
	c.type = ctype
	row.condition = c
	row.target_state_name = target.state_name
	return row


func _mk_machine(mname: String, states: Array) -> SubStateMachine:
	var m := SubStateMachine.new()
	m.machine_name = mname
	var typed: Array[FrameState] = []
	typed.assign(states)
	m.states = typed
	if not typed.is_empty():
		m.entry_state = typed[0]
	return m


func _mk_behavior(machines: Array) -> FrameBehavior:
	var bh := FrameBehavior.new()
	bh.behavior_name = "Test"
	var typed: Array[SubStateMachine] = []
	typed.assign(machines)
	bh.sub_machines = typed
	return bh


func _run_all() -> void:
	# 1. Clean behavior: A <-> B cycle, no issues.
	var a := _mk_state("A")
	var b := _mk_state("B")
	a.transitions = [_mk_row(b)]
	b.transitions = [_mk_row(a)]
	var bh := _mk_behavior([_mk_machine("M", [a, b])])
	var issues := FFValidator.validate_behavior(bh)
	_check(issues.is_empty(), "clean_behavior_no_issues: " + str(issues))

	# 2. Zero-duration state -> error.
	var z := _mk_state("Z", 0)
	z.transitions = [_mk_row(z)]
	issues = FFValidator.validate_behavior(_mk_behavior([_mk_machine("M", [z])]))
	_check(not _issues_with(issues, "error", "zero/negative duration").is_empty(), "zero_duration_error")

	# 3. Unnormalized direction -> warning.
	var u := _mk_state("U")
	u.direction = Vector3(2, 0, 0)
	u.transitions = [_mk_row(u)]
	issues = FFValidator.validate_behavior(_mk_behavior([_mk_machine("M", [u])]))
	_check(not _issues_with(issues, "warning", "not normalized").is_empty(), "unnormalized_warning")

	# 4. Event frame out of range -> error; duplicate event names -> warning.
	var e := _mk_state("E", 5)
	e.transitions = [_mk_row(e)]
	var ev1 := FFStateEvent.new()
	ev1.event_name = "go"
	ev1.trigger = FFStateEvent.Trigger.ON_FRAME
	ev1.frame = 9
	var ev2 := FFStateEvent.new()
	ev2.event_name = "go"
	ev2.trigger = FFStateEvent.Trigger.ON_ENTER
	e.events = [ev1, ev2]
	issues = FFValidator.validate_behavior(_mk_behavior([_mk_machine("M", [e])]))
	_check(not _issues_with(issues, "error", "out of range").is_empty(), "event_frame_range_error")
	_check(not _issues_with(issues, "warning", "more than once").is_empty(), "duplicate_event_warning")

	# 5. Zero rows -> error.
	var t := _mk_state("T")
	issues = FFValidator.validate_behavior(_mk_behavior([_mk_machine("M", [t])]))
	_check(not _issues_with(issues, "error", "no transition rows").is_empty(), "zero_rows_error")

	# 6. Unwired row (no target, no event) -> error.
	var w := _mk_state("W")
	var wrow := FFTransition.new()
	wrow.condition = FFCondition.new()
	w.transitions = [wrow]
	issues = FFValidator.validate_behavior(_mk_behavior([_mk_machine("M", [w])]))
	_check(not _issues_with(issues, "error", "unwired").is_empty(), "unwired_row_error")

	# 7. Fire-event-only row is NOT an unwired error.
	var v := _mk_state("V")
	var vrow := FFTransition.new()
	vrow.condition = FFCondition.new()
	vrow.fire_event = "ping"
	v.transitions = [vrow]
	issues = FFValidator.validate_behavior(_mk_behavior([_mk_machine("M", [v])]))
	_check(_issues_with(issues, "error", "unwired").is_empty(), "event_tap_row_ok")

	# 8. Unreachable state -> warning.
	var r1 := _mk_state("R1")
	r1.transitions = [_mk_row(r1)]
	var r2 := _mk_state("R2")
	r2.transitions = [_mk_row(r2)]
	issues = FFValidator.validate_behavior(_mk_behavior([_mk_machine("M", [r1, r2])]))
	_check(not _issues_with(issues, "warning", "unreachable").is_empty(), "unreachable_warning")

	# 9. Trap: self-loops only -> warning; floor response exit -> no trap.
	var trap := _mk_state("Trap")
	trap.transitions = [_mk_row(trap)]
	issues = FFValidator.validate_behavior(_mk_behavior([_mk_machine("M", [trap])]))
	_check(not _issues_with(issues, "warning", "trap").is_empty(), "trap_warning")
	var land := _mk_state("Land", 5, 0.0, Vector3.ZERO)
	land.transitions = [_mk_row(land)]
	var fall := _mk_state("Fall", 30, 2.0, Vector3.DOWN)
	fall.transitions = [_mk_row(fall)]
	var resp := FFResponse.new()
	resp.target_state_name = land.state_name
	fall.resp_floor = resp
	var mm := _mk_machine("M", [fall, land])
	issues = FFValidator.validate_behavior(_mk_behavior([mm]))
	var fall_traps := _issues_with(issues, "warning", "\"Fall\" looks like a trap")
	_check(fall_traps.is_empty(), "collision_exit_not_trap")

	# 10. Impact-sourced state with no collision target -> warning.
	var imp := _mk_state("Imp", 10, 1.0, Vector3.ZERO)
	imp.direction_source = FrameState.DirectionSource.IMPACT_NORMAL
	imp.transitions = [_mk_row(imp)]
	var idle := _mk_state("Idle", 10, 0.0, Vector3.ZERO)
	idle.transitions = [_mk_row(idle)]
	var mm2 := _mk_machine("M", [imp, idle])
	issues = FFValidator.validate_behavior(_mk_behavior([mm2]))
	_check(not _issues_with(issues, "warning", "no collision response targets it").is_empty(), "impact_untargeted_warning")
	var resp2 := FFResponse.new()
	resp2.target_state_name = imp.state_name
	idle.resp_wall = resp2
	issues = FFValidator.validate_behavior(_mk_behavior([mm2]))
	_check(_issues_with(issues, "warning", "no collision response targets it").is_empty(), "impact_targeted_ok")

	# 11. Preserve into ENTRY target -> warning.
	var src := _mk_state("Src")
	var dst := _mk_state("Dst", 6, 0.0, Vector3.ZERO)
	dst.displacement_source = FrameState.DisplacementSource.ENTRY
	dst.transitions = [_mk_row(dst)]
	var prow := _mk_row(dst)
	prow.momentum = FFTransition.Momentum.PRESERVE
	src.transitions = [prow]
	issues = FFValidator.validate_behavior(_mk_behavior([_mk_machine("M", [src, dst])]))
	_check(not _issues_with(issues, "warning", "redundant with the target's ENTRY").is_empty(), "preserve_entry_warning")

	# 12. On Variable: unknown param -> warning; known -> clean.
	var p := FFParameter.new()
	p.name = "speed"
	var bh12 := _mk_behavior([_mk_machine("M", [a])])
	bh12.parameters = [p]
	var vs := _mk_state("VS")
	var vrow2 := FFTransition.new()
	var vc := FFCondition.new()
	vc.type = FFCondition.Type.ON_VARIABLE
	vc.param_name = "nope"
	vrow2.condition = vc
	vrow2.target_state_name = vs.state_name
	vs.transitions = [vrow2]
	var m12 := _mk_machine("M", [vs])
	bh12.sub_machines = [m12]
	issues = FFValidator.validate_behavior(bh12)
	_check(not _issues_with(issues, "warning", "unknown parameter").is_empty(), "unknown_param_warning")
	vc.param_name = "speed"
	issues = FFValidator.validate_behavior(bh12)
	_check(_issues_with(issues, "warning", "unknown parameter").is_empty(), "known_param_ok")

	# 13. On Input with no actions -> warning.
	var ins := _mk_state("IN")
	var irow := FFTransition.new()
	var ic := FFCondition.new()
	ic.type = FFCondition.Type.ON_INPUT
	irow.condition = ic
	irow.target_state_name = ins.state_name
	ins.transitions = [irow]
	issues = FFValidator.validate_behavior(_mk_behavior([_mk_machine("M", [ins])]))
	_check(not _issues_with(issues, "warning", "no actions assigned").is_empty(), "input_no_actions_warning")

	# 14. Empty machine -> warning; missing entry -> error.
	var mempty := SubStateMachine.new()
	mempty.machine_name = "Empty"
	issues = FFValidator.validate_behavior(_mk_behavior([mempty]))
	_check(not _issues_with(issues, "warning", "has no states").is_empty(), "empty_machine_warning")
	var mnoentry := _mk_machine("NE", [a])
	mnoentry.entry_state = null
	issues = FFValidator.validate_behavior(_mk_behavior([mnoentry]))
	_check(not _issues_with(issues, "error", "no entry state").is_empty(), "no_entry_error")

	# 15. Parallel axes: two machines both author X -> warning.
	var xa := _mk_state("XA", 10, 1.0, Vector3.RIGHT)
	xa.transitions = [_mk_row(xa)]
	var xb := _mk_state("XB", 10, 1.0, Vector3.RIGHT)
	xb.transitions = [_mk_row(xb)]
	issues = FFValidator.validate_behavior(_mk_behavior([_mk_machine("MA", [xa]), _mk_machine("MB", [xb])]))
	_check(not _issues_with(issues, "warning", "both author displacement on the X axis").is_empty(), "parallel_axes_warning")
	var yb := _mk_state("YB", 10, 1.0, Vector3.UP)
	yb.transitions = [_mk_row(yb)]
	issues = FFValidator.validate_behavior(_mk_behavior([_mk_machine("MA", [xa]), _mk_machine("MB", [yb])]))
	_check(_issues_with(issues, "warning", "both author displacement").is_empty(), "different_axes_ok")

	# 16. Behavior transition with no target and no event -> error.
	var bh16 := _mk_behavior([_mk_machine("M", [a])])
	var bt := FFTransition.new()
	bt.condition = FFCondition.new()
	bh16.behavior_transitions = [bt]
	issues = FFValidator.validate_behavior(bh16)
	_check(not _issues_with(issues, "error", "no target behavior").is_empty(), "behavior_transition_error")

	# 17. Duplicate parameter names -> warning.
	var bh17 := _mk_behavior([_mk_machine("M", [a])])
	var p1 := FFParameter.new()
	p1.name = "x"
	var p2 := FFParameter.new()
	p2.name = "x"
	bh17.parameters = [p1, p2]
	issues = FFValidator.validate_behavior(bh17)
	_check(not _issues_with(issues, "warning", "Duplicate parameter").is_empty(), "duplicate_param_warning")
