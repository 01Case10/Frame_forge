extends Node
## Phase 1 headless test driver. Each scenario builds FrameForge resources
## in code, runs them tick-by-tick (many ticks per physics frame), and
## reports PASS/FAIL. Exits with the failure count as the exit code.

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
		TestChain.new(),
		TestJumpNet.new(),
		TestParallel.new(),
		TestEasing.new(),
		TestInput.new(),
		TestBrake.new(),
		TestBlackboard.new(),
		TestSoak.new(),
		TestImpactFallback.new(),
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
	for a in ["t_left", "t_right", "t_forward", "t_back"]:
		if not InputMap.has_action(a):
			InputMap.add_action(a)


func _next() -> void:
	if _queue.is_empty():
		_report()
		return
	_current = _queue.pop_front()
	_current.setup()
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
	_current.player.queue_free()
	_current = null
	_next()


func _report() -> void:
	print("==== Phase 1: %d passed, %d failed ====" % [_passes, _failures.size()])
	if _failures.is_empty():
		print("ALL GREEN")
	get_tree().quit(_failures.size())


# ------------------------------------------------------------------ base case

class TCase:
	var name: String = "case"
	var player: BehaviorPlayer = null
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

	func mk_machine(mname: String, states: Array, entry: FrameState) -> SubStateMachine:
		var m := SubStateMachine.new()
		m.machine_name = mname
		var typed: Array[FrameState] = []
		typed.assign(states)
		m.states = typed
		m.entry_state = entry
		return m

	func mk_behavior(machines: Array) -> FrameBehavior:
		var bh := FrameBehavior.new()
		var typed: Array[SubStateMachine] = []
		typed.assign(machines)
		bh.sub_machines = typed
		return bh

	func mk_player(bh: FrameBehavior) -> BehaviorPlayer:
		var p := BehaviorPlayer.new()
		p.auto_step = false
		p.behavior = bh
		return p


# ------------------------------------------------------------------ scenarios

class TestChain extends TCase:
	func _init() -> void:
		name = "chain_basic"
		total_ticks = 6

	func setup() -> void:
		var a := mk_state("A", 4.0, Vector3(1, 0, 0), 4)
		var b := mk_state("B", 2.0, Vector3(0, 1, 0), 2)
		var rows: Array[FFTransition] = [on_complete_row(b)]
		a.transitions = rows
		player = mk_player(mk_behavior([mk_machine("M", [a, b], a)]))

	func on_tick(tick: int) -> void:
		if tick == 4:
			check_v(player.position, Vector3(4, 0, 0), 1e-4, "pos after A completes")

	func verify() -> void:
		check_v(player.position, Vector3(4, 2, 0), 1e-4, "final pos")
		check(player.current_state_name("M") == "B", "ends in B, got " + player.current_state_name("M"))


class TestJumpNet extends TCase:
	func _init() -> void:
		name = "jump_net_zero"
		total_ticks = 16

	func setup() -> void:
		var r1 := mk_state("RiseFast", 7.0, Vector3(0, 1, 0), 2)
		var r2 := mk_state("RiseSlow", 3.0, Vector3(0, 1, 0), 8)
		var h := mk_state("Hover", 0.0, Vector3(0, 1, 0), 1)
		var f := mk_state("Fall", 10.0, Vector3(0, -1, 0), 5)
		r1.transitions = [on_complete_row(r2)] as Array[FFTransition]
		r2.transitions = [on_complete_row(h)] as Array[FFTransition]
		h.transitions = [on_complete_row(f)] as Array[FFTransition]
		player = mk_player(mk_behavior([mk_machine("V", [r1, r2, h, f], r1)]))

	func verify() -> void:
		check(absf(player.position.y) < 1e-4, "net vertical zero, y=%f" % player.position.y)
		check(absf(player.position.x) < 1e-6, "no horizontal drift")


class TestParallel extends TCase:
	func _init() -> void:
		name = "parallel_sum"
		total_ticks = 4

	func setup() -> void:
		var v := mk_state("Rise", 4.0, Vector3(0, 1, 0), 4)
		var hz := mk_state("Fwd", 3.0, Vector3(1, 0, 0), 4)
		player = mk_player(mk_behavior([
			mk_machine("Vert", [v], v),
			mk_machine("Horiz", [hz], hz),
		]))

	func verify() -> void:
		check_v(player.position, Vector3(3, 4, 0), 1e-4, "parallel sum")


class TestEasing extends TCase:
	var _pre: Array[float] = []

	func _init() -> void:
		name = "easing_exact"
		total_ticks = 3

	func setup() -> void:
		var c := Curve.new()
		c.add_point(Vector2(0, 0))
		c.add_point(Vector2(1, 2))
		var s := mk_state("E", 6.0, Vector3(1, 0, 0), 3)
		s.easing = c
		player = mk_player(mk_behavior([mk_machine("M", [s], s)]))

	func on_tick(_tick: int) -> void:
		_pre.append(player.position.x)

	func verify() -> void:
		_pre.append(player.position.x)
		var d: Array[float] = []
		for i in 3:
			d.append(_pre[i + 1] - _pre[i])
		# Property-based: the plan promises exact totals and shaping,
		# not a specific interpolation scheme.
		check(absf(d[0]) < 1e-4, "ramp starts at 0, got %f" % d[0])
		check(d[0] < d[1] and d[1] < d[2], "strictly increasing, got %s" % str(d))
		check_v(player.position, Vector3(6, 0, 0), 1e-4, "curve integrates exactly to 6")


class TestInput extends TCase:
	func _init() -> void:
		name = "input_direction"
		total_ticks = 20

	func setup() -> void:
		var r := mk_state("Run", 0.1, Vector3.ZERO, 1)
		r.direction_source = FrameState.DirectionSource.INPUT
		r.input_left = "t_left"
		r.input_right = "t_right"
		r.input_forward = "t_forward"
		r.input_back = "t_back"
		r.transitions = [on_complete_row(r)] as Array[FFTransition]
		player = mk_player(mk_behavior([mk_machine("M", [r], r)]))

	func on_tick(tick: int) -> void:
		if tick == 0:
			Input.action_press("t_right")
		elif tick == 10:
			Input.action_release("t_right")
			Input.action_press("t_forward")

	func verify() -> void:
		Input.action_release("t_forward")
		Input.action_release("t_right")
		Input.action_release("t_left")
		Input.action_release("t_back")
		check_v(player.position, Vector3(1.0, 0.0, -1.0), 1e-3, "input steered mid-state")
		check(player.current_state_name("M") == "Run", "never left Run")


class TestBrake extends TCase:
	var _speeds: Array[float] = []
	var _last_x: float = 0.0

	func _init() -> void:
		name = "entry_brake"
		total_ticks = 8

	func setup() -> void:
		var a := mk_state("Run2", 0.2, Vector3(1, 0, 0), 2)
		var b := mk_state("Brake", 0.0, Vector3.ZERO, 4)
		b.direction_source = FrameState.DirectionSource.ENTRY
		b.displacement_source = FrameState.DisplacementSource.ENTRY
		var c := Curve.new()
		c.add_point(Vector2(0, 1))
		c.add_point(Vector2(1, 0))
		b.easing = c
		var idle := mk_state("Idle", 0.0, Vector3.ZERO, 1)
		a.transitions = [on_complete_row(b)] as Array[FFTransition]
		b.transitions = [on_complete_row(idle)] as Array[FFTransition]
		idle.transitions = [on_complete_row(idle)] as Array[FFTransition]
		player = mk_player(mk_behavior([mk_machine("M", [a, b, idle], a)]))

	func on_tick(_tick: int) -> void:
		pass

	func post_tick(tick: int) -> void:
		# Recorded after the tick's move: _speeds[i] is exactly tick i's delta.
		_speeds.append(player.position.x - _last_x)
		_last_x = player.position.x

	func verify() -> void:
		check(_speeds.size() == 8, "8 samples, got %d" % _speeds.size())
		# Ticks 0-1: Run2 at 0.1 u/f. Ticks 2-5: brake. Ticks 6-7: idle.
		check(absf(_speeds[2] - 0.1) < 1e-4, "first brake frame = entry speed 0.1, got %f" % _speeds[2])
		check(_speeds[2] > _speeds[3] and _speeds[3] > _speeds[4] and _speeds[4] > _speeds[5],
			"strictly decreasing, got %s" % str(_speeds.slice(2, 6)))
		check(_speeds[5] < 0.06, "tail decayed, got %f" % _speeds[5])
		check(absf(_speeds[6]) < 1e-4 and absf(_speeds[7]) < 1e-4, "idle after brake")


class TestBlackboard extends TCase:
	func _init() -> void:
		name = "blackboard"
		total_ticks = 1

	func setup() -> void:
		var p1 := FFParameter.new()
		p1.name = "speed"
		p1.ptype = FFParameter.PType.FLOAT
		p1.default_value = 2.5
		var p2 := FFParameter.new()
		p2.name = "grounded"
		p2.ptype = FFParameter.PType.BOOL
		p2.default_value = false
		var s := mk_state("Idle", 0.0, Vector3.ZERO, 1)
		s.transitions = [on_complete_row(s)] as Array[FFTransition]
		var bh := mk_behavior([mk_machine("M", [s], s)])
		var ps: Array[FFParameter] = [p1, p2]
		bh.parameters = ps
		player = mk_player(bh)

	func verify() -> void:
		check(player.get_param("speed") == 2.5, "default float")
		check(player.get_param("grounded") == false, "default bool")
		check(not player.has_param("nope"), "has_param false")
		player.set_param("speed", 4.0)
		check(player.get_param("speed") == 4.0, "set/get roundtrip")


class TestSoak extends TCase:
	func _init() -> void:
		name = "soak_600"
		total_ticks = 600

	func setup() -> void:
		var s := mk_state("Loop", 0.05, Vector3(1, 0, 0), 1)
		s.transitions = [on_complete_row(s)] as Array[FFTransition]
		player = mk_player(mk_behavior([mk_machine("M", [s], s)]))

	func verify() -> void:
		check(absf(player.position.x - 30.0) < 1e-2, "600*0.05=30, got %f" % player.position.x)
		check(is_finite(player.position.x), "no NaN/inf")
		check(player.tick_count() == 600, "tick count 600")


class TestImpactFallback extends TCase:
	func _init() -> void:
		name = "impact_fallback"
		total_ticks = 4

	func setup() -> void:
		var a := mk_state("A", 1.0, Vector3(1, 0, 0), 2)
		var b := mk_state("Bounce", 2.0, Vector3(0, 0, 1), 2)
		b.direction_source = FrameState.DirectionSource.IMPACT_NORMAL
		b.displacement_source = FrameState.DisplacementSource.INCOMING
		a.transitions = [on_complete_row(b)] as Array[FFTransition]
		player = mk_player(mk_behavior([mk_machine("M", [a, b], a)]))

	func verify() -> void:
		# No impact snapshot in phase 1: B must fall back to authored values.
		check_v(player.position, Vector3(1, 0, 2), 1e-4, "fallback to authored")
