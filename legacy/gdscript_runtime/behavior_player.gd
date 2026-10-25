## ARCHIVED — see README.md in this folder. The global BehaviorPlayer
## name now belongs to the Rust GDExtension class.
extends CharacterBody3D
## Phase 3 runtime: 60Hz tick, full conditions, momentum blending,
## behavior switching, per-sub-machine collision pass, plus signals and
## custom timed events.
##
## Signals:
##   state_entered(machine_name, state_name) / state_exited(...)
##   behavior_changed(old_name, new_name)
##   event_fired(event_name) — fires at emission time for every event:
##     transition fire_event, custom state events (enter/exit/frame N),
##     contact-edge events, behavior on-enter/on-exit events, game emit_event.
## A transition with silent=true targeting its own state suppresses the
## enter/exit signals and the enter/exit custom events (frame-N events
## still fire each iteration).
##
## Tick order (deterministic, integer frames):
##   1. _begin_tick() — rotate event sets; sample deterministic input edges.
##   2. Row evaluation per sub-machine, top-to-bottom, first true wins.
##      Rows fire any time, including mid-state interrupts. The frame is
##      NOT advanced here, so a 1-frame state always emits its one frame.
##   3. Compute each track's authored delta (with Preserve blending), sum,
##      drive with a single move_and_slide().
##   4. Collision pass per sub-machine: contact edges, then at most one
##      response per track (priority floor > ceiling > wall). Gained edges
##      are debounced by rearm_ticks; lost edges fire immediately.
##   5. Behavior-level transitions, first true wins.
##   6. Advance each track's frame (clamped at duration: hold final frame).
##      Tracks that entered their state after the delta phase skip this
##      advance, so frame 0 is emitted exactly once, on the next tick.
##
## Event visibility: transition/game events fired during tick N become
## visible to On Event conditions at tick N+1 (order-independent).
## Contact-edge events (floor/wall/ceiling gained/lost) are visible to
## behavior transitions in the SAME tick they occur, and to everything
## from the next tick onward.

const TICKS_PER_SECOND := 60
const DEFAULT_REARM_TICKS := 3
const _EPS := 1e-6


signal state_entered(behavior_name: String, machine_name: String, state_name: String)
signal state_exited(behavior_name: String, machine_name: String, state_name: String)
signal behavior_changed(old_behavior_name: String, new_behavior_name: String)
signal event_fired(event_name: String)


class Track:
	## One live sub-machine instance.
	var machine: SubStateMachine
	var current: FrameState
	var frame: int = 0
	var magnitudes: PackedFloat32Array = PackedFloat32Array()
	var entry_motion: Vector3 = Vector3.ZERO   # pre-entry total delta (u/frame)
	var last_delta: Vector3 = Vector3.ZERO     # this track's delta last tick
	var has_impact: bool = false
	var impact_normal: Vector3 = Vector3.UP
	var impact_rate: float = 0.0              # incoming speed, u/frame
	var blend_from: Vector3 = Vector3.ZERO    # Preserve: entry vector
	var blend_total: int = 0
	var blend_left: int = 0
	# True when the state was entered after this tick's delta phase
	# (collision response / behavior switch): skip the end-of-tick advance
	# so frame 0 is emitted exactly once, next tick.
	var just_entered: bool = false
	var contact_prev := {"floor": false, "ceiling": false, "wall": false}
	var rearm := {"floor": 99, "ceiling": 99, "wall": 99}
	## Lagged INPUT facing (for input_turn_rate_deg); persists per track.
	var last_input_dir: Vector3 = Vector3.ZERO


@export var behavior: FrameBehavior:
	set(v):
		behavior = v
		_rebuild()

## When false, tick() must be called manually (headless deterministic tests).
@export var auto_step := true

## Ticks per second for the behavior clock. The player accumulates physics
## time and calls tick() at this rate (default 60). Set to 30 to play back
## 30Hz-authored content at its native rate.
@export var tick_rate_hz: float = 60.0


var _params: Dictionary = {}
var _tracks: Array[Track] = []
var _tick_count: int = 0
var _tick_accum := 0.0

# Event bus.
var _events_visible: Dictionary = {}   # name -> true (this tick)
var _events_pending: Dictionary = {}   # fired this tick, visible next tick

# Deterministic per-tick input.
var _tracked_actions: Array[String] = []
var _input_down: Dictionary = {}       # action -> pressed this tick
var _input_prev: Dictionary = {}       # action -> pressed last tick
var _input_pressed_edge: Dictionary = {}
var _input_released_edge: Dictionary = {}

var _custom_conditions: Dictionary = {}  # StringName -> Callable
var _switch_impact = null  # one-shot impact snapshot carried across a behavior switch
var _pending_entry := Vector3.ZERO  # entry_motion for tracks built by the next _rebuild
var _has_pending_entry := false
var _pending_just_entered := false
var _delta_phase_done := false  # true after this tick's move (steps 4-6)


func _ready() -> void:
	_rebuild()


func _physics_process(delta: float) -> void:
	if not auto_step:
		return
	_tick_accum += delta
	var interval := 1.0 / maxf(tick_rate_hz, 1.0)
	var guard := 0
	while _tick_accum >= interval and guard < 8:
		_tick_accum -= interval
		guard += 1
		tick()


# ---------------------------------------------------------------- runtime ---

## Advance one tick at the configured tick_rate_hz.
func tick() -> void:
	if behavior == null:
		return
	if _tracks.is_empty():
		_rebuild()
		if _tracks.is_empty():
			return

	_begin_tick()

	# 1. State rows (interrupts + completion), per track. The frame is not
	#    advanced here.
	var snapshot := _tracks.duplicate()
	for t in snapshot:
		if not _tracks.has(t):
			break  # behavior switched mid-loop; new tracks continue below
		_evaluate_rows(t)

	# 2. Authored deltas, summed, one move_and_slide().
	var total := Vector3.ZERO
	for t in _tracks:
		_emit_frame_events(t)
		var d := _compute_delta(t)
		t.last_delta = d
		total += d
	velocity = total * float(TICKS_PER_SECOND)
	move_and_slide()
	_delta_phase_done = true

	# 3. Collision pass.
	_collision_pass()

	# 4. Behavior transitions.
	_behavior_transitions()

	# 5. Advance frames.
	for t in _tracks:
		_advance_frame(t)

	_end_tick()
	_tick_count += 1


func _begin_tick() -> void:
	_events_visible = _events_pending.duplicate()
	_events_pending.clear()
	_delta_phase_done = false
	for a in _tracked_actions:
		var down := Input.is_action_pressed(a)
		_input_pressed_edge[a] = down and not bool(_input_prev.get(a, false))
		_input_released_edge[a] = (not down) and bool(_input_prev.get(a, false))
		_input_down[a] = down


func _end_tick() -> void:
	for a in _tracked_actions:
		_input_prev[a] = bool(_input_down.get(a, false))


## Evaluate one track's rows top-to-bottom. First true row wins.
## Does not touch the frame counter (see _advance_frame).
func _evaluate_rows(t: Track) -> void:
	var st := t.current
	if st == null:
		return
	for row in st.transitions:
		if row == null or row.condition == null:
			continue
		if _condition_true(t, row.condition):
			_fire_transition(t, row)
			return


## Advance one track's frame after its delta was emitted. Clamps at
## duration (hold the final frame); ON_COMPLETE fires on frame >= duration.
## A track that entered its state after this tick's delta phase
## (just_entered) skips the advance so frame 0 emits exactly once.
func _advance_frame(t: Track) -> void:
	if t.just_entered:
		t.just_entered = false
		return
	if t.blend_left > 0:
		t.blend_left -= 1
	var st := t.current
	if st == null:
		return
	t.frame += 1
	var dur := maxi(1, st.duration_frames)
	if t.frame > dur:
		t.frame = dur


func _fire_transition(t: Track, row: FFTransition) -> void:
	if not row.fire_event.is_empty():
		_emit_event(row.fire_event)
	if row.target_behavior != null:
		# Momentum Preserve is intentionally ignored on behavior-switch rows:
		# entry blending is defined per-track against the track's own entry
		# motion; use matched rates or ENTRY sources for cross-behavior
		# continuity (see §3 of the plan).
		_switch_behavior(row.target_behavior)
		return
	if row.resolved_state == null:
		return  # unwired placeholder row: hold
	_enter_state(t, row.resolved_state, row)


func _enter_state(t: Track, new_state: FrameState, row: FFTransition = null,
		impact_normal: Vector3 = Vector3.UP, impact_rate: float = 0.0,
		has_impact: bool = false) -> void:
	if new_state == null:
		return
	var silent_self := row != null and row.silent and row.resolved_state == t.current
	var old_state := t.current
	var bname := behavior.behavior_name if behavior != null else ""
	var machine_name := t.machine.machine_name if t.machine != null else ""
	if not silent_self and old_state != null:
		state_exited.emit(bname, machine_name, old_state.state_name)
		_emit_state_events(old_state, FFStateEvent.Trigger.ON_EXIT)
	t.entry_motion = t.last_delta
	t.current = new_state
	t.frame = 0
	t.just_entered = _delta_phase_done
	t.has_impact = has_impact
	t.impact_normal = impact_normal
	t.impact_rate = impact_rate
	if row != null and row.momentum == FFTransition.Momentum.PRESERVE and row.blend_frames > 0:
		t.blend_total = mini(row.blend_frames, maxi(1, new_state.duration_frames))
		t.blend_left = t.blend_total
		t.blend_from = t.entry_motion
	else:
		t.blend_total = 0
		t.blend_left = 0
	_precompute(t)
	if not silent_self:
		state_entered.emit(bname, machine_name, new_state.state_name)
		_emit_state_events(new_state, FFStateEvent.Trigger.ON_ENTER)


func _switch_behavior(bh: FrameBehavior) -> void:
	if bh == null or bh == behavior:
		return
	var old_bh := behavior
	var old_name := old_bh.behavior_name if old_bh != null else ""
	# Exits (exit/enter pairing holds across switches).
	for t in _tracks:
		if t.current != null:
			var mn := t.machine.machine_name if t.machine != null else ""
			state_exited.emit(old_name, mn, t.current.state_name)
			_emit_state_events(t.current, FFStateEvent.Trigger.ON_EXIT)
	if old_bh != null and not old_bh.on_exit_event.is_empty():
		_emit_event(old_bh.on_exit_event)
	var total_last := Vector3.ZERO
	for t in _tracks:
		total_last += t.last_delta
	# Stash before the setter: _rebuild() applies it to the new tracks
	# BEFORE _precompute, so ENTRY sources bake the fallback rate.
	_pending_entry = total_last
	_has_pending_entry = true
	_pending_just_entered = _delta_phase_done
	behavior = bh  # setter -> _rebuild() (preserves blackboard values)
	_has_pending_entry = false
	_pending_just_entered = false
	for t in _tracks:
		# New tracks inherit current contact state so edges persist
		# across the switch (no phantom re-arm).
		t.contact_prev = {
			"floor": is_on_floor(),
			"ceiling": is_on_ceiling(),
			"wall": is_on_wall(),
		}
		t.rearm = {"floor": 99, "ceiling": 99, "wall": 99}
		if _switch_impact != null:
			t.has_impact = true
			t.impact_normal = _switch_impact["normal"]
			t.impact_rate = _switch_impact["rate"]
	_switch_impact = null
	behavior_changed.emit(old_name, bh.behavior_name)
	if not bh.on_enter_event.is_empty():
		_emit_event(bh.on_enter_event)
	for t in _tracks:
		if t.current != null:
			var mn := t.machine.machine_name if t.machine != null else ""
			state_entered.emit(bh.behavior_name, mn, t.current.state_name)
			_emit_state_events(t.current, FFStateEvent.Trigger.ON_ENTER)


# ------------------------------------------------------------- conditions ---

func _condition_true(t: Track, cond: FFCondition) -> bool:
	match cond.type:
		FFCondition.Type.ON_COMPLETE:
			if t == null or t.current == null:
				return false
			return t.frame >= maxi(1, t.current.duration_frames)
		FFCondition.Type.ON_INPUT:
			return _input_condition(cond)
		FFCondition.Type.ON_VARIABLE:
			return _variable_condition(cond)
		FFCondition.Type.ON_EVENT:
			return bool(_events_visible.get(cond.event_name, false))
		FFCondition.Type.ON_STATE:
			return _state_condition(cond)
		FFCondition.Type.ON_CUSTOM:
			var c: Callable = _custom_conditions.get(cond.custom_name, Callable())
			if c.is_valid():
				return bool(c.call())
			return false
	return false


func _input_condition(cond: FFCondition) -> bool:
	var actions := cond.input_actions
	if actions.is_empty():
		return false
	match cond.input_mode:
		FFCondition.InputMode.ANY_PRESSED:
			for a in actions:
				if bool(_input_pressed_edge.get(a, false)):
					return true
			return false
		FFCondition.InputMode.ANY_RELEASED:
			for a in actions:
				if bool(_input_released_edge.get(a, false)):
					return true
			return false
		FFCondition.InputMode.ALL_RELEASED:
			var any_was := false
			for a in actions:
				if bool(_input_down.get(a, false)):
					return false
				if bool(_input_prev.get(a, false)):
					any_was = true
			return any_was  # fires once: the tick the last key lifts
		FFCondition.InputMode.ANY_HELD:
			for a in actions:
				if bool(_input_down.get(a, false)):
					return true
			return false
	return false


func _variable_condition(cond: FFCondition) -> bool:
	if not has_param(StringName(cond.param_name)):
		return false
	var v: Variant = get_param(StringName(cond.param_name))
	var cv: Variant = cond.param_value
	match cond.param_op:
		FFCondition.Op.EQ:
			return v == cv
		FFCondition.Op.NE:
			return v != cv
		_:
			if not _is_numeric(v) or not _is_numeric(cv):
				return false
			var a := float(v)
			var b := float(cv)
			match cond.param_op:
				FFCondition.Op.GT:
					return a > b
				FFCondition.Op.GE:
					return a >= b
				FFCondition.Op.LT:
					return a < b
				FFCondition.Op.LE:
					return a <= b
	return false


func _is_numeric(v: Variant) -> bool:
	return v is int or v is float


func _state_condition(cond: FFCondition) -> bool:
	if cond.resolved_machine == null or cond.resolved_state == null:
		return false
	for t in _tracks:
		if t.machine == cond.resolved_machine:
			return t.current == cond.resolved_state
	return false


# ------------------------------------------------------------------ input ---

func register_custom_condition(n: StringName, c: Callable) -> void:
	_custom_conditions[n] = c


func _collect_input_actions() -> void:
	_tracked_actions.clear()
	if behavior == null:
		return
	var seen := {}
	for row in behavior.behavior_transitions:
		_gather_row_actions(row, seen)
	for m in behavior.sub_machines:
		if m == null:
			continue
		for st in m.states:
			if st == null:
				continue
			for row in st.transitions:
				_gather_row_actions(row, seen)
	_tracked_actions.assign(seen.keys())


func _gather_row_actions(row: FFTransition, seen: Dictionary) -> void:
	if row == null or row.condition == null:
		return
	if row.condition.type != FFCondition.Type.ON_INPUT:
		return
	for a in row.condition.input_actions:
		if InputMap.has_action(a):
			seen[a] = true


# --------------------------------------------------------------- collision ---

func _collision_pass() -> void:
	var now := {
		"floor": is_on_floor(),
		"ceiling": is_on_ceiling(),
		"wall": is_on_wall(),
	}
	var snapshot := _tracks.duplicate()
	for t in snapshot:
		if not _tracks.has(t):
			break  # behavior switched mid-pass
		_track_collision(t, now)


func _track_collision(t: Track, now: Dictionary) -> void:
	var fired_kind := ""
	for kind in ["floor", "ceiling", "wall"]:
		var is_now := bool(now[kind])
		var was := bool(t.contact_prev[kind])
		if is_now and not was:
			# Gained edges are debounced: rearm counts ticks since the last
			# recognized gained edge, so seam flicker can't retrigger a
			# response while a genuine leave-and-return still can.
			var resp := _effective_response(t, kind)
			var thr := DEFAULT_REARM_TICKS
			if resp != null:
				thr = resp.rearm_ticks
			if int(t.rearm[kind]) >= thr:
				_emit_event_now(kind + "_gained")
				if fired_kind.is_empty():
					fired_kind = kind  # priority: floor > ceiling > wall
				t.rearm[kind] = 0
			else:
				t.rearm[kind] = mini(int(t.rearm[kind]) + 1, 99)
		elif not is_now and was:
			# Lost edges are never debounced: the cliff case needs
			# floor_lost the same tick, even after continuous contact.
			_emit_event_now(kind + "_lost")
			t.rearm[kind] = mini(int(t.rearm[kind]) + 1, 99)
		else:
			t.rearm[kind] = mini(int(t.rearm[kind]) + 1, 99)
		t.contact_prev[kind] = is_now
	if not fired_kind.is_empty():
		_fire_response(t, fired_kind)


func _effective_response(t: Track, kind: String) -> FFResponse:
	var st := t.current
	if st != null:
		match kind:
			"floor":
				if st.resp_floor != null:
					return st.resp_floor
			"ceiling":
				if st.resp_ceiling != null:
					return st.resp_ceiling
			"wall":
				if st.resp_wall != null:
					return st.resp_wall
	if t.machine != null:
		match kind:
			"floor":
				return t.machine.default_resp_floor
			"ceiling":
				return t.machine.default_resp_ceiling
			_:
				return t.machine.default_resp_wall
	return null


## min_incoming_speed is in units/sec; the impact snapshot rate is u/frame.
func _fire_response(t: Track, kind: String) -> void:
	var resp := _effective_response(t, kind)
	if resp == null:
		return
	var incoming_ups := t.last_delta.length() * float(TICKS_PER_SECOND)
	if incoming_ups < resp.min_incoming_speed:
		return
	var n := _impact_normal(kind)
	var rate := t.last_delta.length()
	if resp.target_behavior != null:
		_switch_impact = {"normal": n, "rate": rate}
		_switch_behavior(resp.target_behavior)
		return
	if resp.resolved_state == null:
		return
	_enter_state(t, resp.resolved_state, null, n, rate, true)


func _impact_normal(kind: String) -> Vector3:
	match kind:
		"floor":
			return get_floor_normal()
		"ceiling":
			var best := Vector3.DOWN
			var best_y := 1.0
			for i in get_slide_collision_count():
				var n := get_slide_collision(i).get_normal()
				if n.y < best_y:
					best_y = n.y
					best = n
			return best.normalized() if best_y < -0.5 else Vector3.DOWN
		_:  # wall: most horizontal collision normal
			var best := Vector3.ZERO
			var best_h := 0.0
			for i in get_slide_collision_count():
				var n := get_slide_collision(i).get_normal()
				if absf(n.y) < 0.5:
					var h := Vector2(n.x, n.z).length()
					if h > best_h:
						best_h = h
						best = n
			return best.normalized() if best_h > 0.01 else Vector3.ZERO


# ------------------------------------------------------ behavior transitions ---

func _behavior_transitions() -> void:
	if behavior == null:
		return
	for row in behavior.behavior_transitions:
		if row == null or row.condition == null:
			continue
		if _condition_true(null, row.condition):
			if not row.fire_event.is_empty():
				_emit_event(row.fire_event)
			if row.target_behavior != null and row.target_behavior != behavior:
				_switch_behavior(row.target_behavior)
			return  # first true row wins


# ------------------------------------------------------------------ events ---

## Emit a named event. Visible to On Event conditions starting next tick;
## event_fired fires immediately.
func emit_event(event_name: String) -> void:
	_emit_event(event_name)


## Next-tick-visible emission + immediate event_fired signal.
func _emit_event(event_name: String) -> void:
	if event_name.is_empty():
		return
	_events_pending[event_name] = true
	event_fired.emit(event_name)


## Immediately-visible emission (contact edges) + immediate event_fired.
func _emit_event_now(event_name: String) -> void:
	if event_name.is_empty():
		return
	_events_visible[event_name] = true
	event_fired.emit(event_name)


## Authored per-state events for a trigger (ON_ENTER / ON_EXIT).
func _emit_state_events(st: FrameState, trig: int) -> void:
	if st == null:
		return
	for e in st.events:
		if e != null and e.trigger == trig and not e.event_name.is_empty():
			_emit_event(e.event_name)


## Authored per-state ON_FRAME events matching the track's current frame.
## Fires every tick the track emits that frame, including silent self-loop
## iterations and held final frames.
func _emit_frame_events(t: Track) -> void:
	var st := t.current
	if st == null:
		return
	for e in st.events:
		if e != null and e.trigger == FFStateEvent.Trigger.ON_FRAME \
				and e.frame == t.frame and not e.event_name.is_empty():
			_emit_event(e.event_name)


# --------------------------------------------------------------- blackboard ---

func set_param(n: StringName, v: Variant) -> void:
	_params[n] = v


func get_param(n: StringName) -> Variant:
	return _params.get(n, null)


func has_param(n: StringName) -> bool:
	return _params.has(n)


# ------------------------------------------------------------------ motion ---

func _compute_delta(t: Track) -> Vector3:
	var st := t.current
	if st == null:
		return Vector3.ZERO
	var dir := _resolve_direction(t, st)
	var k := mini(t.frame, t.magnitudes.size() - 1)
	var authored := Vector3.ZERO
	if k >= 0:
		authored = dir * t.magnitudes[k]
	if t.blend_left > 0 and t.blend_total > 0:
		# Preserve: lerp the entry vector toward authored over blend frames.
		# w = (elapsed+1)/total -> 1/blend, 2/blend, ..., 1.0
		var elapsed := t.blend_total - t.blend_left
		var w := clampf(float(elapsed + 1) / float(t.blend_total), 0.0, 1.0)
		return t.blend_from.lerp(authored, w)
	return authored


func _resolve_direction(t: Track, st: FrameState) -> Vector3:
	match st.direction_source:
		FrameState.DirectionSource.AUTHOR:
			return _safe_normalized(st.direction)
		FrameState.DirectionSource.INPUT:
			var target := _input_direction(st)
			var max_deg: float = st.input_turn_rate_deg
			if max_deg <= 0.0 or target == Vector3.ZERO:
				if target != Vector3.ZERO:
					t.last_input_dir = target
				return target
			var prev: Vector3 = t.last_input_dir
			if prev == Vector3.ZERO:
				t.last_input_dir = target
				return target
			var angle := prev.angle_to(target)
			var max_a := deg_to_rad(max_deg)
			if angle <= max_a:
				t.last_input_dir = target
				return target
			var axis := prev.cross(target)
			if axis.length_squared() < 1e-6:
				# Antiparallel: pick a stable axis in the input plane.
				axis = Vector3.UP if st.input_plane == FrameState.InputPlane.XZ else Vector3.BACK
			else:
				axis = axis.normalized()
			t.last_input_dir = prev.rotated(axis, max_a)
			return t.last_input_dir
		FrameState.DirectionSource.ENTRY:
			if t.entry_motion.length_squared() > _EPS * _EPS:
				return t.entry_motion.normalized()
			return _safe_normalized(st.direction)
		FrameState.DirectionSource.IMPACT_NORMAL:
			if t.has_impact:
				return _safe_normalized(t.impact_normal)
			return _safe_normalized(st.direction)
		FrameState.DirectionSource.REFLECTED:
			if t.has_impact:
				if t.last_delta.length_squared() > _EPS * _EPS:
					return _safe_normalized(t.last_delta.bounce(t.impact_normal))
				return _safe_normalized(t.impact_normal)
			return _safe_normalized(st.direction)
	return _safe_normalized(st.direction)


func _input_direction(st: FrameState) -> Vector3:
	var x := Input.get_axis(st.input_left, st.input_right)
	var y := Input.get_axis(st.input_forward, st.input_back)
	var v := Vector2(x, y)
	if v.length() < st.input_deadzone:
		return Vector3.ZERO
	v = v.normalized()
	var yaw := 0.0
	if st.camera_relative:
		var ref := get_node_or_null(st.yaw_reference)
		if ref != null:
			yaw = ref.global_rotation.y
	var s := sin(yaw)
	var c := cos(yaw)
	match st.input_plane:
		FrameState.InputPlane.XZ:
			# Camera-relative: forward (-Z rotated by yaw), right (+X rotated).
			var fwd := Vector3(-s, 0, -c)
			var right := Vector3(c, 0, -s)
			return (right * v.x + fwd * -v.y).normalized()
		_:
			return Vector3(v.x, v.y, 0.0).normalized()


func _safe_normalized(v: Vector3) -> Vector3:
	if v.length_squared() < _EPS * _EPS:
		return Vector3.ZERO
	return v.normalized()


# ------------------------------------------------------------------ setup ---

func _rebuild() -> void:
	var old_params := _params.duplicate()
	_tracks.clear()
	_params.clear()
	if behavior == null:
		return
	_resolve_references()
	for p in behavior.parameters:
		if p == null:
			continue
		# Preserve game-written values for same-named params across switches.
		_params[p.name] = old_params.get(p.name, p.default_value)
	for m in behavior.sub_machines:
		if m == null or m.entry_state == null:
			continue
		var t := Track.new()
		t.machine = m
		t.current = m.entry_state
		t.frame = 0
		if _has_pending_entry:
			t.entry_motion = _pending_entry
			t.just_entered = _pending_just_entered
		_precompute(t)
		_tracks.append(t)
	_collect_input_actions()


## Resolve name-based state/machine references into the runtime caches.
## Called on every rebuild (assignment, switch); the editor calls
## refresh_resolution() after renames so previews stay correct.
func refresh_resolution() -> void:
	_resolve_references()


func _resolve_references() -> void:
	if behavior == null:
		return
	var machines := {}
	for m in behavior.sub_machines:
		if m != null:
			machines[m.machine_name] = m
	for m in behavior.sub_machines:
		if m == null:
			continue
		var states := {}
		for s in m.states:
			if s != null and not states.has(s.state_name):
				states[s.state_name] = s
		for s in m.states:
			if s == null:
				continue
			for row in s.transitions:
				if row == null:
					continue
				row.resolved_state = states.get(row.target_state_name, null)
				var c: FFCondition = row.condition
				if c != null and c.type == FFCondition.Type.ON_STATE:
					c.resolved_machine = machines.get(c.target_machine_name, null)
					var sm: SubStateMachine = c.resolved_machine
					c.resolved_state = null
					if sm != null:
						for cs in sm.states:
							if cs != null and cs.state_name == c.target_state_name:
								c.resolved_state = cs
								break
			for resp in [s.resp_floor, s.resp_ceiling, s.resp_wall]:
				if resp != null:
					resp.resolved_state = states.get(resp.target_state_name, null)
		for resp in [m.default_resp_floor, m.default_resp_ceiling, m.default_resp_wall]:
			if resp != null:
				resp.resolved_state = states.get(resp.target_state_name, null)


func _precompute(t: Track) -> void:
	var st := t.current
	var n := maxi(1, st.duration_frames)
	t.magnitudes = PackedFloat32Array()
	t.magnitudes.resize(n)
	var ds := st.displacement_source
	# INCOMING without a fresh impact falls back to authored.
	if ds == FrameState.DisplacementSource.INCOMING and not t.has_impact:
		ds = FrameState.DisplacementSource.AUTHOR
	if ds == FrameState.DisplacementSource.INCOMING:
		# Rate-based: impact u/frame x restitution, shaped by easing.
		var rate := t.impact_rate * st.restitution
		for k in n:
			var shape := st.easing.sample(float(k) / float(n))
			t.magnitudes[k] = rate * shape
	elif ds == FrameState.DisplacementSource.ENTRY:
		# Rate-based: pre-entry u/frame, shaped by easing.
		var rate := t.entry_motion.length()
		for k in n:
			var shape := st.easing.sample(float(k) / float(n))
			t.magnitudes[k] = rate * shape
	else:
		# AUTHOR: normalized so the total equals displacement exactly.
		var weights := PackedFloat32Array()
		weights.resize(n)
		var wsum := 0.0
		for k in n:
			var w := st.easing.sample(float(k) / float(n))
			weights[k] = w
			wsum += w
		if wsum < _EPS:
			return
		for k in n:
			t.magnitudes[k] = st.displacement * weights[k] / wsum


# -------------------------------------------------------------- inspection ---

func tick_count() -> int:
	return _tick_count


func current_state_name(machine_name: String) -> String:
	for t in _tracks:
		if t.machine != null and t.machine.machine_name == machine_name:
			return t.current.state_name if t.current != null else "<none>"
	return "<no-machine>"


func current_frame(machine_name: String) -> int:
	for t in _tracks:
		if t.machine != null and t.machine.machine_name == machine_name:
			return t.frame
	return -1
