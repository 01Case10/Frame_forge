extends Node
## Phase 2 headless test driver: full conditions, momentum blending,
## behavior switching, and the collision pass.
## Reports PASS/FAIL; exits with the failure count as the exit code.

const TICKS_PER_FRAME := 25

var _queue: Array = []
var _current: TCase = null
var _ticks_left: int = 0
var _tick_index: int = 0
var _passes: int = 0
var _failures: Array[String] = []


func _ready() -> void:
	_ensure_input_actions()
	_queue = [
		TestPriority.new(),
		TestPriorityFallthrough.new(),
		TestInputPressed.new(),
		TestInputAllReleased.new(),
		TestVariableOps.new(),
		TestEventDelay.new(),
		TestOnState.new(),
		TestCustom.new(),
		TestPreserve.new(),
		TestCut.new(),
		TestBehaviorSwitch.new(),
		TestParamPreserved.new(),
		TestEntrySwitch.new(),
		TestFloorLand.new(),
		TestWallBounce.new(),
		TestMinSpeed.new(),
		TestWallRearm.new(),
		TestFloorLost.new(),
	]
	_next()


func _physics_process(_delta: float) -> void:
	if _current == null:
		return
	var n: int = mini(TICKS_PER_FRAME, _ticks_left)
	for i in n:
		_current.on_tick(_tick_index)
		_current.player.tick()
		_current.post_tick(_tick_index)
		_tick_index += 1
	_ticks_left -= n
	if _ticks_left <= 0:
		_finish()


func _ensure_input_actions() -> void:
	for a in ["t_left", "t_right", "t_forward", "t_back", "t_jump"]:
		if not InputMap.has_action(a):
			InputMap.add_action(a)


func _next() -> void:
	if _queue.is_empty():
		_report()
		return
	_current = _queue.pop_front()
	_current.setup()
	for s in _current.statics:
		add_child(s)
	add_child(_current.player)
	_ticks_left = _current.total_ticks
	_tick_index = 0


func _finish() -> void:
	_current.verify()
	if _current.failures.is_empty():
		_passes += 1
		print("[PASS] ", _current.name)
	else:
		print("[FAIL] ", _current.name)
		for f in _current.failures:
			_failures.append(_current.name + ": " + f)
			print("    - ", f)
	for s in _current.statics:
		s.queue_free()
	_current.player.queue_free()
	_current = null
	_next()


func _report() -> void:
	print("==== Phase 2: %d passed, %d failed ====" % [_passes, _failures.size()])
	if _failures.is_empty():
		print("ALL GREEN")
	get_tree().quit(_failures.size())


# ------------------------------------------------------------------ base case

class TCase:
	var name: String = "case"
	var player: BehaviorPlayer = null
	var statics: Array[Node] = []
	var total_ticks: int = 1
	var failures: Array[String] = []

	func setup() -> void:
		pass

	func on_tick(_tick: int) -> void:
		pass

	func post_tick(_tick: int) -> void:
		pass

	func verify() -> void:
		pass

	func check(c: bool, msg: String) -> void:
		if not c:
			failures.append(msg)

	func check_v(actual: Vector3, expected: Vector3, eps: float, msg: String) -> void:
		if actual.distance_to(expected) > eps:
			failures.append("%s — got %s expected %s" % [msg, str(actual), str(expected)])

	func mk_state(sname: String, disp: float, dir: Vector3, dur: int) -> FrameState:
		var s := FrameState.new()
		s.state_name = sname
		s.displacement = disp
		s.direction = dir
		s.duration_frames = dur
		return s

	func on_complete_row(target: FrameState) -> FFTransition:
		var cond := FFCondition.new()
		cond.type = FFCondition.Type.ON_COMPLETE
		var r := FFTransition.new()
		r.condition = cond
		r.target_state_name = target.state_name
		return r

	func c_input(actions: Array, mode: int) -> FFCondition:
		var c := FFCondition.new()
		c.type = FFCondition.Type.ON_INPUT
		var pa := PackedStringArray()
		for a in actions:
			pa.append(a)
		c.input_actions = pa
		c.input_mode = mode
		return c

	func c_var(pname: String, op: int, val: Variant) -> FFCondition:
		var c := FFCondition.new()
		c.type = FFCondition.Type.ON_VARIABLE
		c.param_name = pname
		c.param_op = op
		c.param_value = val
		return c

	func c_event(ename: String) -> FFCondition:
		var c := FFCondition.new()
		c.type = FFCondition.Type.ON_EVENT
		c.event_name = ename
		return c

	func c_state(m: SubStateMachine, s: FrameState) -> FFCondition:
		var c := FFCondition.new()
		c.type = FFCondition.Type.ON_STATE
		c.target_machine_name = m.machine_name
		c.target_state_name = s.state_name
		return c

	func c_custom(cname: StringName) -> FFCondition:
		var c := FFCondition.new()
		c.type = FFCondition.Type.ON_CUSTOM
		c.custom_name = cname
		return c

	func row_to(cond: FFCondition, target: FrameState,
			momentum: int = FFTransition.Momentum.CUT, blend: int = 3) -> FFTransition:
		var r := FFTransition.new()
		r.condition = cond
		r.target_state_name = target.state_name
		r.momentum = momentum
		r.blend_frames = blend
		return r

	func brow_to(cond: FFCondition, target: FrameBehavior) -> FFTransition:
		var r := FFTransition.new()
		r.condition = cond
		r.target_behavior = target
		return r

	func mk_resp(target: FrameState, min_speed: float = 0.0, rearm: int = 3) -> FFResponse:
		var r := FFResponse.new()
		r.target_state_name = target.state_name
		r.min_incoming_speed = min_speed
		r.rearm_ticks = rearm
		return r

	func mk_machine(mname: String, states: Array, entry: FrameState) -> SubStateMachine:
		var m := SubStateMachine.new()
		m.machine_name = mname
		var typed: Array[FrameState] = []
		typed.assign(states)
		m.states = typed
		m.entry_state = entry
		return m

	func mk_behavior(machines: Array, bname: String = "Behavior") -> FrameBehavior:
		var bh := FrameBehavior.new()
		bh.behavior_name = bname
		var typed: Array[SubStateMachine] = []
		typed.assign(machines)
		bh.sub_machines = typed
		return bh

	func add_param(bh: FrameBehavior, pname: String, ptype: int, def: Variant) -> void:
		var p := FFParameter.new()
		p.name = pname
		p.ptype = ptype
		p.default_value = def
		bh.parameters.append(p)

	func mk_player(bh: FrameBehavior) -> BehaviorPlayer:
		var p := BehaviorPlayer.new()
		p.auto_step = false
		# Capsule body so move_and_slide() collides (r=0.3, h=1.0).
		var cs := CollisionShape3D.new()
		var cap := CapsuleShape3D.new()
		cap.radius = 0.3
		cap.height = 1.0
		cs.shape = cap
		p.add_child(cs)
		p.behavior = bh
		return p

	func mk_floor() -> StaticBody3D:
		# Top surface at y = 0.
		var body := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(10, 1, 10)
		cs.shape = box
		body.position = Vector3(0, -0.5, 0)
		body.add_child(cs)
		return body

	func mk_wall() -> StaticBody3D:
		# Face at x = 5, spanning y 0..4.
		var body := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(1, 4, 4)
		cs.shape = box
		body.position = Vector3(5.5, 2, 0)
		body.add_child(cs)
		return body


# ------------------------------------------------------------------ scenarios

class TestPriority extends TCase:
	# Both rows true at tick 2; the first row must win.
	var _states: Array[String] = []

	func _init() -> void:
		name = "cond_priority"
		total_ticks = 4

	func setup() -> void:
		var a := mk_state("A", 0.0, Vector3.ZERO, 3)
		var b := mk_state("B", 0.0, Vector3.ZERO, 1)
		var c := mk_state("C", 0.0, Vector3.ZERO, 1)
		b.transitions = [on_complete_row(b)] as Array[FFTransition]
		c.transitions = [on_complete_row(c)] as Array[FFTransition]
		a.transitions = [
			row_to(c_var("go", FFCondition.Op.EQ, true), b),
			on_complete_row(c),
		] as Array[FFTransition]
		var bh := mk_behavior([mk_machine("M", [a, b, c], a)])
		add_param(bh, "go", FFParameter.PType.BOOL, false)
		player = mk_player(bh)

	func on_tick(tick: int) -> void:
		if tick == 2:
			player.set_param(&"go", true)

	func post_tick(_tick: int) -> void:
		_states.append(player.current_state_name("M"))

	func verify() -> void:
		check(_states[0] == "A" and _states[1] == "A", "stays A, got %s" % str(_states))
		check(_states[2] == "B", "variable row wins over On Complete, got " + _states[2])
		check(not _states.has("C"), "C never entered")


class TestPriorityFallthrough extends TCase:
	var _states: Array[String] = []

	func _init() -> void:
		name = "cond_priority_fallthrough"
		total_ticks = 4

	func setup() -> void:
		var a := mk_state("A", 0.0, Vector3.ZERO, 3)
		var b := mk_state("B", 0.0, Vector3.ZERO, 1)
		var c := mk_state("C", 0.0, Vector3.ZERO, 1)
		b.transitions = [on_complete_row(b)] as Array[FFTransition]
		c.transitions = [on_complete_row(c)] as Array[FFTransition]
		a.transitions = [
			row_to(c_var("go", FFCondition.Op.EQ, true), b),
			on_complete_row(c),
		] as Array[FFTransition]
		var bh := mk_behavior([mk_machine("M", [a, b, c], a)])
		add_param(bh, "go", FFParameter.PType.BOOL, false)
		player = mk_player(bh)

	func post_tick(_tick: int) -> void:
		_states.append(player.current_state_name("M"))

	func verify() -> void:
		check(_states[3] == "C", "falls through to On Complete, got " + _states[3])
		check(not _states.has("B"), "B never entered")


class TestInputPressed extends TCase:
	# Edge semantics: hold must not retrigger; release+press must.
	var _states: Array[String] = []

	func _init() -> void:
		name = "cond_input_edges"
		total_ticks = 9

	func setup() -> void:
		var a := mk_state("A", 0.0, Vector3.ZERO, 5)
		var b := mk_state("B", 0.0, Vector3.ZERO, 1)
		a.transitions = [
			row_to(c_input(["t_jump"], FFCondition.InputMode.ANY_PRESSED), b),
		] as Array[FFTransition]
		b.transitions = [
			row_to(c_input(["t_jump"], FFCondition.InputMode.ANY_PRESSED), a),
			on_complete_row(b),
		] as Array[FFTransition]
		player = mk_player(mk_behavior([mk_machine("M", [a, b], a)]))

	func on_tick(tick: int) -> void:
		if tick == 2 or tick == 7:
			Input.action_press("t_jump")
		elif tick == 6:
			Input.action_release("t_jump")

	func post_tick(_tick: int) -> void:
		_states.append(player.current_state_name("M"))

	func verify() -> void:
		Input.action_release("t_jump")
		check(_states[0] == "A" and _states[1] == "A", "starts in A")
		check(_states[2] == "B", "press edge -> B, got " + _states[2])
		check(_states[3] == "B" and _states[4] == "B" and _states[5] == "B",
			"hold does not retrigger, got %s" % str(_states))
		check(_states[6] == "B", "release alone does nothing")
		check(_states[7] == "A", "second press edge -> A, got " + _states[7])


class TestInputAllReleased extends TCase:
	# The brake idiom: fires once, on the tick the last key lifts.
	var _states: Array[String] = []

	func _init() -> void:
		name = "cond_input_all_released"
		total_ticks = 6

	func setup() -> void:
		var run := mk_state("Run", 0.1, Vector3(1, 0, 0), 1)
		var idle := mk_state("Idle", 0.0, Vector3.ZERO, 1)
		run.transitions = [
			row_to(c_input(["t_right"], FFCondition.InputMode.ALL_RELEASED), idle),
			on_complete_row(run),
		] as Array[FFTransition]
		idle.transitions = [on_complete_row(idle)] as Array[FFTransition]
		player = mk_player(mk_behavior([mk_machine("M", [run, idle], run)]))

	func on_tick(tick: int) -> void:
		if tick == 0:
			Input.action_press("t_right")
		elif tick == 4:
			Input.action_release("t_right")

	func post_tick(_tick: int) -> void:
		_states.append(player.current_state_name("M"))

	func verify() -> void:
		Input.action_release("t_right")
		var want := ["Run", "Run", "Run", "Run", "Idle", "Idle"]
		check(_states == want, "brake idiom timing, got %s" % str(_states))


class TestVariableOps extends TCase:
	var _states: Array[String] = []

	func _init() -> void:
		name = "cond_variable"
		total_ticks = 4

	func setup() -> void:
		var a := mk_state("A", 0.0, Vector3.ZERO, 4)
		var b := mk_state("B", 0.0, Vector3.ZERO, 1)
		a.transitions = [row_to(c_var("n", FFCondition.Op.GT, 5.0), b)] as Array[FFTransition]
		b.transitions = [on_complete_row(b)] as Array[FFTransition]
		var bh := mk_behavior([mk_machine("M", [a, b], a)])
		add_param(bh, "n", FFParameter.PType.FLOAT, 3.0)
		player = mk_player(bh)

	func on_tick(tick: int) -> void:
		if tick == 2:
			player.set_param(&"n", 7.0)

	func post_tick(_tick: int) -> void:
		_states.append(player.current_state_name("M"))

	func verify() -> void:
		check(_states[0] == "A" and _states[1] == "A", "3.0 not > 5.0")
		check(_states[2] == "B", "7.0 > 5.0 fires, got " + _states[2])


class TestEventDelay extends TCase:
	# Game events are visible starting the NEXT tick (order-independent).
	var _states: Array[String] = []

	func _init() -> void:
		name = "cond_event_delay"
		total_ticks = 5

	func setup() -> void:
		var a := mk_state("A", 0.0, Vector3.ZERO, 6)
		var b := mk_state("B", 0.0, Vector3.ZERO, 1)
		a.transitions = [row_to(c_event("go"), b)] as Array[FFTransition]
		b.transitions = [on_complete_row(b)] as Array[FFTransition]
		player = mk_player(mk_behavior([mk_machine("M", [a, b], a)]))

	func post_tick(tick: int) -> void:
		_states.append(player.current_state_name("M"))
		if tick == 2:
			player.emit_event("go")

	func verify() -> void:
		check(_states[2] == "A", "not visible same tick, got " + _states[2])
		check(_states[3] == "B", "visible next tick, got " + _states[3])


class TestOnState extends TCase:
	var _m2: Array[String] = []

	func _init() -> void:
		name = "cond_on_state"
		total_ticks = 3

	func setup() -> void:
		var a := mk_state("A", 0.0, Vector3.ZERO, 2)
		var b := mk_state("B", 0.0, Vector3.ZERO, 1)
		var x := mk_state("X", 0.0, Vector3.ZERO, 6)
		var y := mk_state("Y", 0.0, Vector3.ZERO, 1)
		a.transitions = [on_complete_row(b)] as Array[FFTransition]
		b.transitions = [on_complete_row(b)] as Array[FFTransition]
		y.transitions = [on_complete_row(y)] as Array[FFTransition]
		var m1 := mk_machine("M1", [a, b], a)
		var m2 := mk_machine("M2", [x, y], x)
		x.transitions = [row_to(c_state(m1, b), y)] as Array[FFTransition]
		player = mk_player(mk_behavior([m1, m2]))

	func post_tick(_tick: int) -> void:
		_m2.append(player.current_state_name("M2"))

	func verify() -> void:
		check(_m2[0] == "X" and _m2[1] == "X", "waits, got %s" % str(_m2))
		check(_m2[2] == "Y", "M1==B seen (machine order), got " + _m2[2])


class TestCustom extends TCase:
	var _states: Array[String] = []

	func _init() -> void:
		name = "cond_custom"
		total_ticks = 4

	func setup() -> void:
		var a := mk_state("A", 0.0, Vector3.ZERO, 4)
		var b := mk_state("B", 0.0, Vector3.ZERO, 1)
		a.transitions = [row_to(c_custom(&"go3"), b)] as Array[FFTransition]
		b.transitions = [on_complete_row(b)] as Array[FFTransition]
		player = mk_player(mk_behavior([mk_machine("M", [a, b], a)]))
		player.register_custom_condition(&"go3", func() -> bool:
			return player.tick_count() >= 2
		)

	func post_tick(_tick: int) -> void:
		_states.append(player.current_state_name("M"))

	func verify() -> void:
		check(_states[0] == "A" and _states[1] == "A", "callable false early")
		check(_states[2] == "B", "callable true at tick 2, got " + _states[2])


class TestPreserve extends TCase:
	var _speeds: Array[float] = []
	var _last_x := 0.0

	func _init() -> void:
		name = "momentum_preserve"
		total_ticks = 5

	func setup() -> void:
		var a := mk_state("A", 0.12, Vector3(1, 0, 0), 1)
		var b := mk_state("B", 0.0, Vector3.ZERO, 4)
		a.transitions = [
			row_to(on_complete_row(b).condition, b, FFTransition.Momentum.PRESERVE, 4),
		] as Array[FFTransition]
		player = mk_player(mk_behavior([mk_machine("M", [a, b], a)]))

	func post_tick(_tick: int) -> void:
		_speeds.append(player.position.x - _last_x)
		_last_x = player.position.x

	func verify() -> void:
		var want := [0.12, 0.09, 0.06, 0.03, 0.0]
		for i in 5:
			check(absf(_speeds[i] - want[i]) < 1e-4,
				"blend frame %d: got %f want %f" % [i, _speeds[i], want[i]])
		check(absf(player.position.x - 0.3) < 1e-4, "total 0.3, got %f" % player.position.x)


class TestCut extends TCase:
	var _speeds: Array[float] = []
	var _last_x := 0.0

	func _init() -> void:
		name = "momentum_cut"
		total_ticks = 5

	func setup() -> void:
		var a := mk_state("A", 0.12, Vector3(1, 0, 0), 1)
		var b := mk_state("B", 0.0, Vector3.ZERO, 4)
		a.transitions = [on_complete_row(b)] as Array[FFTransition]  # CUT default
		player = mk_player(mk_behavior([mk_machine("M", [a, b], a)]))

	func post_tick(_tick: int) -> void:
		_speeds.append(player.position.x - _last_x)
		_last_x = player.position.x

	func verify() -> void:
		check(absf(_speeds[0] - 0.12) < 1e-4, "authored first frame")
		for i in [1, 2, 3, 4]:
			check(absf(_speeds[i]) < 1e-4, "cut frame %d is 0, got %f" % [i, _speeds[i]])
		check(absf(player.position.x - 0.12) < 1e-4, "total 0.12")


class TestBehaviorSwitch extends TCase:
	var _bh: Array[String] = []
	var _st: Array[String] = []

	func _init() -> void:
		name = "behavior_switch"
		total_ticks = 8

	func setup() -> void:
		var idle_a := mk_state("IdleA", 0.0, Vector3.ZERO, 1)
		idle_a.transitions = [on_complete_row(idle_a)] as Array[FFTransition]
		var fall_b := mk_state("FallB", 0.05, Vector3(0, -1, 0), 1)
		fall_b.transitions = [on_complete_row(fall_b)] as Array[FFTransition]
		var ground := mk_behavior([mk_machine("M", [idle_a], idle_a)], "Ground")
		var air := mk_behavior([mk_machine("M", [fall_b], fall_b)], "Air")
		var g2a: Array[FFTransition] = [brow_to(c_input(["t_jump"], FFCondition.InputMode.ANY_PRESSED), air)]
		var a2g: Array[FFTransition] = [brow_to(c_input(["t_jump"], FFCondition.InputMode.ANY_PRESSED), ground)]
		ground.behavior_transitions = g2a
		air.behavior_transitions = a2g
		player = mk_player(ground)

	func on_tick(tick: int) -> void:
		if tick == 2 or tick == 5:
			Input.action_press("t_jump")
		elif tick == 3 or tick == 6:
			Input.action_release("t_jump")

	func post_tick(_tick: int) -> void:
		_bh.append(player.behavior.behavior_name)
		_st.append(player.current_state_name("M"))

	func verify() -> void:
		Input.action_release("t_jump")
		check(_bh[1] == "Ground", "still Ground before press")
		check(_bh[2] == "Air" and _st[2] == "FallB", "switched to Air/FallB, got %s/%s" % [_bh[2], _st[2]])
		check(_bh[4] == "Air", "stays Air while held")
		check(_bh[5] == "Ground" and _st[5] == "IdleA", "back to Ground, got %s/%s" % [_bh[5], _st[5]])
		check(absf(player.position.y - (-0.15)) < 1e-4, "fell 3 ticks x 0.05, y=%f" % player.position.y)


class TestParamPreserved extends TCase:
	func _init() -> void:
		name = "behavior_switch_params"
		total_ticks = 4

	func setup() -> void:
		var idle_a := mk_state("IdleA", 0.0, Vector3.ZERO, 1)
		idle_a.transitions = [on_complete_row(idle_a)] as Array[FFTransition]
		var fall_b := mk_state("FallB", 0.0, Vector3.ZERO, 1)
		fall_b.transitions = [on_complete_row(fall_b)] as Array[FFTransition]
		var ground := mk_behavior([mk_machine("M", [idle_a], idle_a)], "Ground")
		var air := mk_behavior([mk_machine("M", [fall_b], fall_b)], "Air")
		add_param(ground, "speed", FFParameter.PType.FLOAT, 1.0)
		add_param(air, "speed", FFParameter.PType.FLOAT, 1.0)
		var g2a: Array[FFTransition] = [brow_to(c_input(["t_jump"], FFCondition.InputMode.ANY_PRESSED), air)]
		ground.behavior_transitions = g2a
		player = mk_player(ground)

	func on_tick(tick: int) -> void:
		if tick == 1:
			player.set_param(&"speed", 9.0)
		elif tick == 2:
			Input.action_press("t_jump")

	func verify() -> void:
		Input.action_release("t_jump")
		check(player.behavior.behavior_name == "Air", "switched")
		check(player.get_param(&"speed") == 9.0, "game-written param survives switch, got %s" % str(player.get_param(&"speed")))


class TestEntrySwitch extends TCase:
	# Fresh behavior: ENTRY falls back to the player's total pre-switch delta.
	func _init() -> void:
		name = "behavior_switch_entry_fallback"
		total_ticks = 5

	func setup() -> void:
		var run := mk_state("Run", 0.1, Vector3(1, 0, 0), 1)
		run.transitions = [on_complete_row(run)] as Array[FFTransition]
		var drift := mk_state("Drift", 0.0, Vector3.ZERO, 2)
		drift.direction_source = FrameState.DirectionSource.ENTRY
		drift.displacement_source = FrameState.DisplacementSource.ENTRY
		var ground := mk_behavior([mk_machine("M", [run], run)], "Ground")
		var air := mk_behavior([mk_machine("M", [drift], drift)], "Air")
		var g2a: Array[FFTransition] = [brow_to(c_input(["t_jump"], FFCondition.InputMode.ANY_PRESSED), air)]
		ground.behavior_transitions = g2a
		player = mk_player(ground)

	func on_tick(tick: int) -> void:
		if tick == 2:
			Input.action_press("t_jump")

	func verify() -> void:
		Input.action_release("t_jump")
		check(player.behavior.behavior_name == "Air", "switched")
		check(player.current_state_name("M") == "Drift", "in Drift")
		# Ticks 0,1: Run (0.2). Tick 2: Run (0.3), switch at end.
		# Ticks 3,4: Drift at entry rate 0.1 -> 0.5.
		check(absf(player.position.x - 0.5) < 1e-4, "entry fallback 0.1/frame, x=%f" % player.position.x)


class TestFloorLand extends TCase:
	var _lands: Array[int] = []

	func _init() -> void:
		name = "collision_floor_land"
		total_ticks = 30

	func setup() -> void:
		statics.append(mk_floor())
		var fall := mk_state("Fall", 0.15, Vector3(0, -1, 0), 1)
		fall.transitions = [on_complete_row(fall)] as Array[FFTransition]
		var land := mk_state("Land", 0.0, Vector3.ZERO, 2)
		var idle := mk_state("Idle", 0.0, Vector3.ZERO, 1)
		land.transitions = [on_complete_row(idle)] as Array[FFTransition]
		idle.transitions = [on_complete_row(idle)] as Array[FFTransition]
		var m := mk_machine("M", [fall, land, idle], fall)
		m.default_resp_floor = mk_resp(land)
		player = mk_player(mk_behavior([m]))
		player.position = Vector3(0, 3, 0)

	func post_tick(tick: int) -> void:
		var s := player.current_state_name("M")
		if s == "Land" and _prev != "Land":
			_lands.append(tick)
		_prev = s

	var _prev := ""

	func verify() -> void:
		check(_lands.size() == 1, "Land entered exactly once, got %s" % str(_lands))
		if not _lands.is_empty():
			check(_lands[0] == 16, "landing tick 16, got %d" % _lands[0])
		check(player.current_state_name("M") == "Idle", "settles to Idle, got " + player.current_state_name("M"))
		check(absf(player.position.y - 0.5) < 0.05, "rests on floor, y=%f" % player.position.y)


class TestWallBounce extends TCase:
	var _bounces: Array[int] = []
	var _xs: Array[float] = []

	func _init() -> void:
		name = "collision_wall_bounce"
		total_ticks = 34

	func setup() -> void:
		statics.append(mk_wall())
		var run := mk_state("Run", 0.2, Vector3(1, 0, 0), 1)
		run.transitions = [on_complete_row(run)] as Array[FFTransition]
		var bounce := mk_state("Bounce", 0.0, Vector3.ZERO, 4)
		bounce.direction_source = FrameState.DirectionSource.IMPACT_NORMAL
		bounce.displacement_source = FrameState.DisplacementSource.INCOMING
		bounce.restitution = 0.5
		var done := mk_state("Done", 0.0, Vector3.ZERO, 1)
		done.transitions = [on_complete_row(done)] as Array[FFTransition]
		bounce.transitions = [on_complete_row(done)] as Array[FFTransition]
		var m := mk_machine("M", [run, bounce, done], run)
		m.default_resp_wall = mk_resp(bounce)
		player = mk_player(mk_behavior([m]))
		player.position = Vector3(0, 0.5, 0)

	func post_tick(tick: int) -> void:
		_xs.append(player.position.x)
		var s := player.current_state_name("M")
		if s == "Bounce" and _prev != "Bounce":
			_bounces.append(tick)
		_prev = s
		if tick == 23:
			_entry_x = player.position.x

	var _prev := ""
	var _entry_x := 0.0

	func verify() -> void:
		check(_bounces == [23], "Bounce entered exactly once at tick 23, got %s" % str(_bounces))
		# Ticks 24-27: rebound at 0.1 u/f (0.2 * 0.5) along -X.
		for i in [24, 25, 26, 27]:
			var d: float = _xs[i - 1] - _xs[i]
			check(absf(d - 0.1) < 1e-3, "bounce frame %d moves -0.1, got %f" % [i, d])
		check(absf((_entry_x - player.position.x) - 0.4) < 1e-3,
			"rebounded 0.4 total, got %f" % (_entry_x - player.position.x))
		check(player.current_state_name("M") == "Done", "ends in Done, got " + player.current_state_name("M"))


class TestMinSpeed extends TCase:
	var _states: Array[String] = []

	func _init() -> void:
		name = "collision_min_speed"
		total_ticks = 30

	func setup() -> void:
		statics.append(mk_wall())
		var run := mk_state("Run", 0.2, Vector3(1, 0, 0), 1)
		run.transitions = [on_complete_row(run)] as Array[FFTransition]
		var bounce := mk_state("Bounce", 0.0, Vector3.ZERO, 4)
		bounce.direction_source = FrameState.DirectionSource.IMPACT_NORMAL
		bounce.displacement_source = FrameState.DisplacementSource.INCOMING
		var m := mk_machine("M", [run, bounce], run)
		# 0.2 u/f = 12 u/s < 100 u/s: response must stay suppressed.
		m.default_resp_wall = mk_resp(bounce, 100.0)
		player = mk_player(mk_behavior([m]))
		player.position = Vector3(0, 0.5, 0)

	func post_tick(_tick: int) -> void:
		_states.append(player.current_state_name("M"))

	func verify() -> void:
		check(not _states.has("Bounce"), "bounce suppressed by min_incoming_speed")
		check(_states[_states.size() - 1] == "Run", "still pushing")
		check(absf(player.position.x - 4.7) < 0.05, "pressed against wall, x=%f" % player.position.x)


class TestWallRearm extends TCase:
	# No retrigger while sliding along the wall; refire after a genuine
	# leave-and-return.
	var _entries: Array[int] = []

	func _init() -> void:
		name = "collision_wall_rearm"
		total_ticks = 65

	func setup() -> void:
		statics.append(mk_wall())
		var run := mk_state("Run", 0.2, Vector3(1, 0, 0), 1)
		run.transitions = [on_complete_row(run)] as Array[FFTransition]
		var slide := mk_state("SlideB", 0.15, Vector3(0.2, 0, 1).normalized(), 10)
		slide.transitions = [on_complete_row(run)] as Array[FFTransition]
		var m := mk_machine("M", [run, slide], run)
		m.default_resp_wall = mk_resp(slide, 0.0, 3)
		player = mk_player(mk_behavior([m]))
		player.position = Vector3(0, 0.5, 0)

	func on_tick(tick: int) -> void:
		if tick == 36:
			player.position = Vector3(0, 0.5, 0)  # teleport away: leave

	func post_tick(tick: int) -> void:
		var s := player.current_state_name("M")
		if s == "SlideB" and _prev != "SlideB":
			_entries.append(tick)
		_prev = s

	var _prev := ""

	func verify() -> void:
		check(_entries == [23, 59], "entries at first touch + genuine return, got %s" % str(_entries))


class TestFloorLost extends TCase:
	func _init() -> void:
		name = "collision_floor_lost"
		total_ticks = 28

	func setup() -> void:
		statics.append(mk_floor())
		var fall := mk_state("Fall", 0.15, Vector3(0, -1, 0), 1)
		fall.transitions = [on_complete_row(fall)] as Array[FFTransition]
		var land := mk_state("Land", 0.0, Vector3.ZERO, 2)
		var settle := mk_state("Settle", 0.005, Vector3(0, -1, 0), 1)
		land.transitions = [on_complete_row(settle)] as Array[FFTransition]
		settle.transitions = [on_complete_row(settle)] as Array[FFTransition]
		var m := mk_machine("M", [fall, land, settle], fall)
		m.default_resp_floor = mk_resp(land)
		var ground := mk_behavior([m], "Ground")
		var fall2 := mk_state("Fall2", 0.1, Vector3(0, -1, 0), 1)
		fall2.transitions = [on_complete_row(fall2)] as Array[FFTransition]
		var air := mk_behavior([mk_machine("M", [fall2], fall2)], "Air")
		var g2a: Array[FFTransition] = [brow_to(c_event("floor_lost"), air)]
		ground.behavior_transitions = g2a
		player = mk_player(ground)
		player.position = Vector3(0, 3, 0)

	func on_tick(tick: int) -> void:
		if tick == 24:
			player.position = Vector3(0, 5, 0)  # walk off the cliff

	func verify() -> void:
		check(player.behavior.behavior_name == "Air", "floor_lost -> Air, got " + player.behavior.behavior_name)
		check(player.current_state_name("M") == "Fall2", "in Fall2, got " + player.current_state_name("M"))
