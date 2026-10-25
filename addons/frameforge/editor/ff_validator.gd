class_name FFValidator
extends RefCounted
## Pure-logic validation for FrameForge behaviors. Returns an Array of
## Dictionaries: { severity: "error"|"warning", message: String,
##   machine: SubStateMachine (nullable), state: FrameState (nullable) }.
## No editor dependencies — fully headless-testable.


static func validate_behavior(bh: FrameBehavior) -> Array:
	var issues: Array = []
	if bh == null:
		return issues
	_check_parameters(bh, issues)
	for m in bh.sub_machines:
		if m != null:
			_validate_machine(bh, m, issues)
	_check_behavior_transitions(bh, issues)
	_check_parallel_axes(bh, issues)
	return issues


static func _issue(issues: Array, severity: String, message: String, machine: SubStateMachine = null, state: FrameState = null) -> void:
	issues.append({
		"severity": severity,
		"message": message,
		"machine": machine,
		"state": state,
	})


static func _check_parameters(bh: FrameBehavior, issues: Array) -> void:
	var seen := {}
	for p in bh.parameters:
		if p == null:
			continue
		if p.name.is_empty():
			_issue(issues, "warning", "Parameter with empty name.", null, null)
		elif seen.has(p.name):
			_issue(issues, "warning", "Duplicate parameter name \"%s\"." % p.name, null, null)
		else:
			seen[p.name] = true


static func _validate_machine(bh: FrameBehavior, m: SubStateMachine, issues: Array) -> void:
	if m.states.is_empty():
		_issue(issues, "warning", "Sub-machine \"%s\" has no states." % m.machine_name, m)
		return
	if m.entry_state == null:
		_issue(issues, "error", "Sub-machine \"%s\" has no entry state." % m.machine_name, m)
	elif not m.states.has(m.entry_state):
		_issue(issues, "error", "Sub-machine \"%s\": entry state \"%s\" is not in its state list." % [m.machine_name, m.entry_state.state_name], m)

	# State names are the reference keys: duplicates break resolution.
	var seen_names := {}
	for s in m.states:
		if s == null:
			continue
		if seen_names.has(s.state_name):
			_issue(issues, "error",
				"Sub-machine \"%s\": duplicate state name \"%s\"." % [m.machine_name, s.state_name], m, s)
		else:
			seen_names[s.state_name] = true

	var reachable := _reachable_states(m)
	for s in m.states:
		if s == null:
			continue
		_validate_state(bh, m, s, reachable, issues)

	# Impact-source reachability: states fed by collision must be targeted
	# by at least one collision response in the same machine.
	var collision_targets := {}
	for s in m.states:
		if s == null:
			continue
		for resp in [s.resp_floor, s.resp_ceiling, s.resp_wall,
				m.default_resp_floor, m.default_resp_ceiling, m.default_resp_wall]:
			if resp != null and not String(resp.target_state_name).is_empty():
				var rname := String(resp.target_state_name)
				collision_targets[rname] = true
				if _find_state(m, rname) == null:
					_issue(issues, "error",
						"State \"%s\": collision response targets unknown state \"%s\"." % [s.state_name, rname], m, s)
	for s in m.states:
		if s == null:
			continue
		var impact_fed := s.direction_source == FrameState.DirectionSource.IMPACT_NORMAL \
			or s.direction_source == FrameState.DirectionSource.REFLECTED \
			or s.displacement_source == FrameState.DisplacementSource.INCOMING
		if impact_fed and not collision_targets.has(s.state_name):
			_issue(issues, "warning",
				"State \"%s\" uses impact/incoming sources but no collision response targets it." % s.state_name, m, s)


static func _validate_state(bh: FrameBehavior, m: SubStateMachine, s: FrameState, reachable: Dictionary, issues: Array) -> void:
	if s.duration_frames <= 0:
		_issue(issues, "error", "State \"%s\" has zero/negative duration." % s.state_name, m, s)
	if s.direction_source == FrameState.DirectionSource.AUTHOR and s.displacement > 0.0:
		if absf(s.direction.length() - 1.0) > 0.01:
			_issue(issues, "warning",
				"State \"%s\" direction is not normalized (length %.3f)." % [s.state_name, s.direction.length()], m, s)
	if not reachable.has(s):
		_issue(issues, "warning", "State \"%s\" is unreachable from the entry state." % s.state_name, m, s)

	# Events.
	var names := {}
	for ev in s.events:
		if ev == null:
			continue
		if ev.event_name.is_empty():
			_issue(issues, "warning", "State \"%s\" has an event with an empty name." % s.state_name, m, s)
		elif names.has(ev.event_name):
			_issue(issues, "warning",
				"State \"%s\" fires \"%s\" more than once." % [s.state_name, ev.event_name], m, s)
		else:
			names[ev.event_name] = true
		if ev.trigger == FFStateEvent.Trigger.ON_FRAME and (ev.frame < 0 or ev.frame >= maxi(1, s.duration_frames)):
			_issue(issues, "error",
				"State \"%s\": event \"%s\" frame %d out of range (0..%d)." % [s.state_name, ev.event_name, ev.frame, maxi(1, s.duration_frames) - 1], m, s)

	# Transition rows.
	if s.transitions.is_empty():
		_issue(issues, "error",
			"State \"%s\" has no transition rows (terminal states are not allowed)." % s.state_name, m, s)
		return
	var trap := true
	for row in s.transitions:
		if row == null:
			continue
		var target_name := String(row.target_state_name)
		if target_name.is_empty() and row.target_behavior == null and row.fire_event.is_empty():
			_issue(issues, "error",
				"State \"%s\" has an unwired transition row (no target, no event)." % s.state_name, m, s)
		if not target_name.is_empty() and _find_state(m, target_name) == null:
			_issue(issues, "error",
				"State \"%s\": row targets unknown state \"%s\"." % [s.state_name, target_name], m, s)
		if _row_leaves(row, s):
			trap = false
		_validate_condition(bh, m, s, row, issues)
		# Preserve is redundant when the target reads ENTRY sources.
		if row.momentum == FFTransition.Momentum.PRESERVE and not target_name.is_empty():
			var t := _find_state(m, target_name)
			if t != null and (t.direction_source == FrameState.DirectionSource.ENTRY \
					or t.displacement_source == FrameState.DisplacementSource.ENTRY):
				_issue(issues, "warning",
					"Row in \"%s\" → \"%s\": Preserve momentum is redundant with the target's ENTRY sources." % [s.state_name, target_name], m, s)
	# Collision responses (own + inherited machine defaults) are exit paths too.
	for resp in [s.resp_floor, s.resp_ceiling, s.resp_wall,
			m.default_resp_floor, m.default_resp_ceiling, m.default_resp_wall]:
		if resp != null and _response_leaves(resp, s):
			trap = false
	if trap:
		_issue(issues, "warning",
			"State \"%s\" looks like a trap: no row or collision response leaves it." % s.state_name, m, s)

	# Input direction sanity.
	if s.direction_source == FrameState.DirectionSource.INPUT:
		if s.input_left.is_empty() and s.input_right.is_empty() \
				and s.input_forward.is_empty() and s.input_back.is_empty():
			_issue(issues, "warning",
				"State \"%s\" uses Input direction but no input actions are assigned." % s.state_name, m, s)

	# G-6: state logic sanity.
	var known_logics := ["wallrun", "ledgegrab", "poleclimb"]
	if not s.logic.is_empty():
		if not known_logics.has(s.logic):
			_issue(issues, "error",
				"State \"%s\" names unknown state logic \"%s\" (known: %s)." % [s.state_name, s.logic, ", ".join(PackedStringArray(known_logics))], m, s)
		if s.steer != null:
			_issue(issues, "warning",
				"State \"%s\" sets both steer and logic; the logic owns the delta and steer is ignored." % s.state_name, m, s)

	# G-4: param assigns (state enter_params + row on_fire_params).
	_validate_param_assigns(s.enter_params, "enter_params", m, s, issues)
	for row in s.transitions:
		if row != null:
			_validate_param_assigns(row.on_fire_params, "on_fire_params", m, s, issues)

	# G-5: steer sanity.
	if s.steer != null:
		_validate_steer(s.steer, m, s, issues)


static func _find_state(m: SubStateMachine, state_name: String) -> FrameState:
	for s in m.states:
		if s != null and s.state_name == state_name:
			return s
	return null


static func _row_leaves(row: FFTransition, s: FrameState) -> bool:
	if row.target_behavior != null:
		return true
	var target_name := String(row.target_state_name)
	return not target_name.is_empty() and target_name != s.state_name


static func _response_leaves(resp: FFResponse, s: FrameState) -> bool:
	if resp.target_behavior != null:
		return true
	var target_name := String(resp.target_state_name)
	return not target_name.is_empty() and target_name != s.state_name


static func _validate_condition(bh: FrameBehavior, m: SubStateMachine, s: FrameState, row: FFTransition, issues: Array) -> void:
	var c: FFCondition = row.condition
	if c == null:
		_issue(issues, "warning", "State \"%s\" has a row with no condition (never fires)." % s.state_name, m, s)
		return
	_check_condition(bh, m, s, c, issues)


static func _check_condition(bh: FrameBehavior, m: SubStateMachine, s: FrameState, c: FFCondition, issues: Array) -> void:
	# Composites define the condition (the core ignores `type` then);
	# validate the children, recursively.
	if not c.all_of.is_empty() or not c.any_of.is_empty():
		for k in c.all_of:
			if k != null:
				_check_condition(bh, m, s, k, issues)
		for k in c.any_of:
			if k != null:
				_check_condition(bh, m, s, k, issues)
		return
	match c.type:
		FFCondition.Type.ON_INPUT:
			if c.input_actions.is_empty():
				_issue(issues, "warning",
					"State \"%s\": On Input row has no actions assigned." % s.state_name, m, s)
		FFCondition.Type.ON_VARIABLE:
			var known := false
			for p in bh.parameters:
				if p != null and p.name == c.param_name:
					known = true
					break
			if not known:
				_issue(issues, "warning",
					"State \"%s\": On Variable row references unknown parameter \"%s\"." % [s.state_name, c.param_name], m, s)
		FFCondition.Type.ON_EVENT:
			if c.event_name.is_empty():
				_issue(issues, "warning", "State \"%s\": On Event row has no event name." % s.state_name, m, s)
		FFCondition.Type.ON_STATE:
			if String(c.target_machine_name).is_empty() or String(c.target_state_name).is_empty():
				_issue(issues, "warning",
					"State \"%s\": On State row is missing its machine/state." % s.state_name, m, s)
			else:
				var tm: SubStateMachine = null
				for om in bh.sub_machines:
					if om != null and om.machine_name == String(c.target_machine_name):
						tm = om
						break
				if tm == null:
					_issue(issues, "warning",
						"State \"%s\": On State row targets unknown machine \"%s\"." % [s.state_name, String(c.target_machine_name)], m, s)
				elif _find_state(tm, String(c.target_state_name)) == null:
					_issue(issues, "warning",
						"State \"%s\": On State row targets unknown state \"%s\"." % [s.state_name, String(c.target_state_name)], m, s)
		FFCondition.Type.ON_CUSTOM:
			if String(c.custom_name).is_empty():
				_issue(issues, "warning", "State \"%s\": On Custom row has no name." % s.state_name, m, s)


static func _reachable_states(m: SubStateMachine) -> Dictionary:
	var seen := {}
	if m.entry_state == null:
		return seen
	var stack: Array = [m.entry_state]
	while not stack.is_empty():
		var s: FrameState = stack.pop_back()
		if s == null or seen.has(s):
			continue
		seen[s] = true
		for row in s.transitions:
			if row != null and not String(row.target_state_name).is_empty():
				var target := _find_state(m, String(row.target_state_name))
				if target != null:
					stack.append(target)
	return seen


static func _check_behavior_transitions(bh: FrameBehavior, issues: Array) -> void:
	for row in bh.behavior_transitions:
		if row == null:
			continue
		if row.target_behavior == null and row.fire_event.is_empty():
			_issue(issues, "error", "Behavior transition has no target behavior and no event.", null, null)
		if row.condition == null:
			_issue(issues, "warning", "Behavior transition has no condition (never fires).", null, null)


static func _check_parallel_axes(bh: FrameBehavior, issues: Array) -> void:
	# Warn when two sub-machines both author displacement on the same axis.
	var machines := bh.sub_machines
	for i in machines.size():
		for j in range(i + 1, machines.size()):
			var a: SubStateMachine = machines[i]
			var b: SubStateMachine = machines[j]
			if a == null or b == null:
				continue
			var axes_a := _authored_axes(a)
			var axes_b := _authored_axes(b)
			for ax in ["x", "y", "z"]:
				if axes_a.get(ax, false) and axes_b.get(ax, false):
					_issue(issues, "warning",
						"Sub-machines \"%s\" and \"%s\" both author displacement on the %s axis." % [a.machine_name, b.machine_name, ax.to_upper()],
						null, null)


static func _authored_axes(m: SubStateMachine) -> Dictionary:
	var axes := {"x": false, "y": false, "z": false}
	for s in m.states:
		if s == null:
			continue
		if s.displacement <= 0.0:
			continue
		if s.direction_source != FrameState.DirectionSource.AUTHOR:
			continue
		var d := s.direction.normalized()
		if absf(d.x) > 0.5:
			axes["x"] = true
		if absf(d.y) > 0.5:
			axes["y"] = true
		if absf(d.z) > 0.5:
			axes["z"] = true
	return axes

## G-4: validate blackboard writes (mirrors Rust `validate_param_assigns`).
static func _validate_param_assigns(assigns: Array[FFParamAssign], field: String, m: SubStateMachine, s: FrameState, issues: Array) -> void:
	for a in assigns:
		if a == null:
			continue
		if a.name.is_empty():
			_issue(issues, "warning",
				"State \"%s\": %s has an assign with an empty parameter name." % [s.state_name, field], m, s)
		if a.kind == FFParamAssign.Kind.COUNTDOWN and a.ticks == 0:
			_issue(issues, "warning",
				"State \"%s\": %s countdown \"%s\" has 0 ticks (never positive)." % [s.state_name, field, a.name], m, s)

## G-5: sanity checks on a steering config (mirrors Rust `validate_steer`).
static func _validate_steer(st: FFSteerConfig, m: SubStateMachine, s: FrameState, issues: Array) -> void:
	if st.decay < 0.0 or st.decay >= 1.0:
		_issue(issues, "warning",
			"State \"%s\": steer decay %s is outside [0, 1); it is ignored." % [s.state_name, st.decay], m, s)
	if st.gravity < 0.0:
		_issue(issues, "warning",
			"State \"%s\": steer gravity %s is negative (positive = downward); check the sign." % [s.state_name, st.gravity], m, s)
	if st.terminal_velocity < 0.0:
		_issue(issues, "warning",
			"State \"%s\": steer terminal_velocity %s is negative; it is ignored." % [s.state_name, st.terminal_velocity], m, s)
	var prev_max := -1.0
	for i in st.turn_tiers.size():
		var t := st.turn_tiers[i]
		if t == null:
			continue
		if t.speed_max <= prev_max:
			_issue(issues, "warning",
				"State \"%s\": steer turn tier %d speed_max %s is not above the previous tier's; tiers are first-match-wins." % [s.state_name, i, t.speed_max], m, s)
		prev_max = t.speed_max
		if t.cap_base < 0.0:
			_issue(issues, "warning",
				"State \"%s\": steer turn tier %d has a negative cap_base." % [s.state_name, i], m, s)
