extends Node
## Phase 3 headless test driver: signals, custom timed events,
## transition events, and silent self-loop semantics.
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
		TestSignalsBasic.new(),
		TestSilentSelfLoop.new(),
		TestNonSilentSelfLoop.new(),
		TestBehaviorChanged.new(),
		TestTransitionEvent.new(),
		TestContactEventSignal.new(),
		TestFrameNEvent.new(),
		TestEnterExitEvents.new(),
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
	for a in ["t_jump"]:
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
	print("==== Phase 3: %d passed, %d failed ====" % [_passes, _failures.size()])
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

	func mk_event(ename: String, trig: int, frame: int = 0) -> FFStateEvent:
		var e := FFStateEvent.new()
		e.event_name = ename
		e.trigger = trig
		e.frame = frame
		return e

	func add_events(s: FrameState, evs: Array) -> void:
		var typed: Array[FFStateEvent] = []
		typed.assign(evs)
		s.events = typed

	func c_input(actions: Array, mode: int) -> FFCondition:
		var c := FFCondition.new()
		c.type = FFCondition.Type.ON_INPUT
		var pa := PackedStringArray()
		for a in actions:
			pa.append(a)
		c.input_actions = pa
		c.input_mode = mode
		return c

	func brow_to(cond: FFCondition, target: FrameBehavior) -> FFTransition:
		var r := FFTransition.new()
		r.condition = cond
		r.target_behavior = target
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

	func mk_player(bh: FrameBehavior) -> BehaviorPlayer:
		var p := BehaviorPlayer.new()
		p.auto_step = false
		var cs := CollisionShape3D.new()
		var cap := CapsuleShape3D.new()
		cap.radius = 0.3
		cap.height = 1.0
		cs.shape = cap
		p.add_child(cs)
		p.behavior = bh
		return p

	func mk_floor() -> StaticBody3D:
		var body := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(10, 1, 10)
		cs.shape = box
		body.position = Vector3(0, -0.5, 0)
		body.add_child(cs)
		return body

	func watch(p: BehaviorPlayer) -> Dictionary:
		var log := {"log": [], "fired": []}
		p.state_entered.connect(func(bn: String, mn: String, sn: String): log["log"].append("enter " + bn + "/" + mn + "/" + sn))
		p.state_exited.connect(func(bn: String, mn: String, sn: String): log["log"].append("exit " + bn + "/" + mn + "/" + sn))
		p.behavior_changed.connect(func(o: String, n: String): log["log"].append("behavior " + o + "->" + n))
		p.event_fired.connect(func(e: String): log["fired"].append(e))
		return log


# ------------------------------------------------------------------ scenarios

class TestSignalsBasic extends TCase:
	var _log: Dictionary = {}

	func _init() -> void:
		name = "signals_basic"
		total_ticks = 4

	func setup() -> void:
		var a := mk_state("A", 0.0, Vector3.ZERO, 2)
		var b := mk_state("B", 0.0, Vector3.ZERO, 1)
		a.transitions = [on_complete_row(b)] as Array[FFTransition]
		var bs := on_complete_row(b)
		bs.silent = true
		b.transitions = [bs] as Array[FFTransition]
		player = mk_player(mk_behavior([mk_machine("M", [a, b], a)]))
		_log = watch(player)

	func verify() -> void:
		# Initial build is silent; only the A->B transition signals.
		check(_log["log"] == ["exit Behavior/M/A", "enter Behavior/M/B"],
			"exit-then-enter pairing, got %s" % str(_log["log"]))


class TestSilentSelfLoop extends TCase:
	var _log: Dictionary = {}

	func _init() -> void:
		name = "signals_silent_selfloop"
		total_ticks = 4

	func setup() -> void:
		var a := mk_state("A", 0.0, Vector3.ZERO, 1)
		var r := on_complete_row(a)
		r.silent = true
		a.transitions = [r] as Array[FFTransition]
		add_events(a, [
			mk_event("tick", FFStateEvent.Trigger.ON_FRAME, 0),
			mk_event("enter_a", FFStateEvent.Trigger.ON_ENTER),
		])
		player = mk_player(mk_behavior([mk_machine("M", [a], a)]))
		_log = watch(player)

	func verify() -> void:
		check(_log["log"].is_empty(), "no enter/exit on silent self-loop, got %s" % str(_log["log"]))
		check(_log["fired"].filter(func(e: String): return e == "tick").size() == 4,
			"frame-0 event each iteration, got %s" % str(_log["fired"]))
		check(not _log["fired"].has("enter_a"), "enter event suppressed, got %s" % str(_log["fired"]))


class TestNonSilentSelfLoop extends TCase:
	var _log: Dictionary = {}

	func _init() -> void:
		name = "signals_loud_selfloop"
		total_ticks = 3

	func setup() -> void:
		var a := mk_state("A", 0.0, Vector3.ZERO, 1)
		a.transitions = [on_complete_row(a)] as Array[FFTransition]  # silent=false
		player = mk_player(mk_behavior([mk_machine("M", [a], a)]))
		_log = watch(player)

	func verify() -> void:
		# Ticks 1 and 2 re-enter; tick 0 has no transition yet.
		check(_log["log"] == ["exit Behavior/M/A", "enter Behavior/M/A", "exit Behavior/M/A", "enter Behavior/M/A"],
			"loud self-loop signals each re-entry, got %s" % str(_log["log"]))


class TestBehaviorChanged extends TCase:
	var _log: Dictionary = {}

	func _init() -> void:
		name = "signals_behavior_changed"
		total_ticks = 5

	func setup() -> void:
		var idle_a := mk_state("IdleA", 0.0, Vector3.ZERO, 1)
		var ia := on_complete_row(idle_a)
		ia.silent = true
		idle_a.transitions = [ia] as Array[FFTransition]
		var fall_b := mk_state("FallB", 0.0, Vector3.ZERO, 1)
		var fb := on_complete_row(fall_b)
		fb.silent = true
		fall_b.transitions = [fb] as Array[FFTransition]
		var ground := mk_behavior([mk_machine("M", [idle_a], idle_a)], "Ground")
		var air := mk_behavior([mk_machine("M", [fall_b], fall_b)], "Air")
		var g2a: Array[FFTransition] = [brow_to(c_input(["t_jump"], FFCondition.InputMode.ANY_PRESSED), air)]
		ground.behavior_transitions = g2a
		ground.on_exit_event = "ground_bye"
		air.on_enter_event = "air_hi"
		player = mk_player(ground)
		_log = watch(player)

	func on_tick(tick: int) -> void:
		if tick == 2:
			Input.action_press("t_jump")

	func verify() -> void:
		Input.action_release("t_jump")
		check(_log["log"] == ["exit Ground/M/IdleA", "behavior Ground->Air", "enter Air/M/FallB"],
			"exit/behavior/enter order, got %s" % str(_log["log"]))
		check(_log["fired"] == ["ground_bye", "air_hi"],
			"behavior on-exit/on-enter events, got %s" % str(_log["fired"]))


class TestTransitionEvent extends TCase:
	var _log: Dictionary = {}

	func _init() -> void:
		name = "signals_transition_event"
		total_ticks = 4

	func setup() -> void:
		var a := mk_state("A", 0.0, Vector3.ZERO, 2)
		var b := mk_state("B", 0.0, Vector3.ZERO, 1)
		var r := on_complete_row(b)
		r.fire_event = "jumped"
		a.transitions = [r] as Array[FFTransition]
		b.transitions = [on_complete_row(b)] as Array[FFTransition]
		player = mk_player(mk_behavior([mk_machine("M", [a, b], a)]))
		_log = watch(player)

	func verify() -> void:
		check(_log["fired"] == ["jumped"],
			"transition fire_event signals once, got %s" % str(_log["fired"]))


class TestContactEventSignal extends TCase:
	var _log: Dictionary = {}

	func _init() -> void:
		name = "signals_contact_event"
		total_ticks = 20

	func setup() -> void:
		statics.append(mk_floor())
		var fall := mk_state("Fall", 0.15, Vector3(0, -1, 0), 1)
		fall.transitions = [on_complete_row(fall)] as Array[FFTransition]
		var land := mk_state("Land", 0.0, Vector3.ZERO, 2)
		land.transitions = [on_complete_row(land)] as Array[FFTransition]
		var m := mk_machine("M", [fall, land], fall)
		var resp := FFResponse.new()
		resp.target_state_name = land.state_name
		m.default_resp_floor = resp
		player = mk_player(mk_behavior([m]))
		player.position = Vector3(0, 3, 0)
		_log = watch(player)

	func verify() -> void:
		check(_log["fired"].has("floor_gained"), "floor_gained signaled, got %s" % str(_log["fired"]))


class TestFrameNEvent extends TCase:
	var _log: Dictionary = {}

	func _init() -> void:
		name = "signals_frame_n_event"
		total_ticks = 5

	func setup() -> void:
		var a := mk_state("A", 0.0, Vector3.ZERO, 3)
		var b := mk_state("B", 0.0, Vector3.ZERO, 1)
		add_events(a, [
			mk_event("mid", FFStateEvent.Trigger.ON_FRAME, 1),
			mk_event("never", FFStateEvent.Trigger.ON_FRAME, 5),
		])
		a.transitions = [on_complete_row(b)] as Array[FFTransition]
		b.transitions = [on_complete_row(b)] as Array[FFTransition]
		player = mk_player(mk_behavior([mk_machine("M", [a, b], a)]))
		_log = watch(player)

	func verify() -> void:
		check(_log["fired"] == ["mid"],
			"frame-1 fires once, frame-5 never, got %s" % str(_log["fired"]))


class TestEnterExitEvents extends TCase:
	var _log: Dictionary = {}

	func _init() -> void:
		name = "signals_enter_exit_events"
		total_ticks = 4

	func setup() -> void:
		var a := mk_state("A", 0.0, Vector3.ZERO, 2)
		var b := mk_state("B", 0.0, Vector3.ZERO, 1)
		add_events(a, [
			mk_event("a_enter", FFStateEvent.Trigger.ON_ENTER),
			mk_event("a_exit", FFStateEvent.Trigger.ON_EXIT),
		])
		add_events(b, [mk_event("b_enter", FFStateEvent.Trigger.ON_ENTER)])
		a.transitions = [on_complete_row(b)] as Array[FFTransition]
		var bs := on_complete_row(b)
		bs.silent = true
		b.transitions = [bs] as Array[FFTransition]
		player = mk_player(mk_behavior([mk_machine("M", [a, b], a)]))
		_log = watch(player)

	func verify() -> void:
		# Initial build emits nothing; the A->B transition exits A then enters B.
		check(_log["fired"] == ["a_exit", "b_enter"],
			"exit-then-enter event order, got %s" % str(_log["fired"]))
