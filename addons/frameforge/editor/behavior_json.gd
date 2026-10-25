class_name BehaviorJSON
extends RefCounted
## JSON persistence for FrameForge behaviors (the JSON-canonical format).
## Converts between the Godot Resource tree (FrameBehavior, ...) and the
## snake_case JSON dicts that `ff` and the Rust core read/write.
## Replaces .tres persistence in the editor.

# ------------------------------------------------------------------ enums ---

static func _dir_src_to_str(v: int) -> String:
	match v:
		FrameState.DirectionSource.AUTHOR: return "author"
		FrameState.DirectionSource.IMPACT_NORMAL: return "impact_normal"
		FrameState.DirectionSource.REFLECTED: return "reflected"
		FrameState.DirectionSource.INPUT: return "input"
		FrameState.DirectionSource.ENTRY: return "entry"
	return "author"

static func _dir_src_from_str(s: String) -> int:
	match s:
		"impact_normal": return FrameState.DirectionSource.IMPACT_NORMAL
		"reflected": return FrameState.DirectionSource.REFLECTED
		"input": return FrameState.DirectionSource.INPUT
		"entry": return FrameState.DirectionSource.ENTRY
	return FrameState.DirectionSource.AUTHOR

static func _disp_src_to_str(v: int) -> String:
	match v:
		FrameState.DisplacementSource.AUTHOR: return "author"
		FrameState.DisplacementSource.INCOMING: return "incoming"
		FrameState.DisplacementSource.ENTRY: return "entry"
	return "author"

static func _disp_src_from_str(s: String) -> int:
	match s:
		"incoming": return FrameState.DisplacementSource.INCOMING
		"entry": return FrameState.DisplacementSource.ENTRY
	return FrameState.DisplacementSource.AUTHOR

static func _plane_to_str(v: int) -> String:
	return "xy" if v == FrameState.InputPlane.XY else "xz"

static func _plane_from_str(s: String) -> int:
	return FrameState.InputPlane.XY if s == "xy" else FrameState.InputPlane.XZ

static func _cond_type_to_str(v: int) -> String:
	match v:
		FFCondition.Type.ON_COMPLETE: return "on_complete"
		FFCondition.Type.ON_INPUT: return "on_input"
		FFCondition.Type.ON_VARIABLE: return "on_variable"
		FFCondition.Type.ON_EVENT: return "on_event"
		FFCondition.Type.ON_STATE: return "on_state"
		FFCondition.Type.ON_CUSTOM: return "on_custom"
		FFCondition.Type.ON_STICK: return "on_stick"
	return "on_complete"

static func _cond_type_from_str(s: String) -> int:
	match s:
		"on_input": return FFCondition.Type.ON_INPUT
		"on_variable": return FFCondition.Type.ON_VARIABLE
		"on_event": return FFCondition.Type.ON_EVENT
		"on_state": return FFCondition.Type.ON_STATE
		"on_custom": return FFCondition.Type.ON_CUSTOM
		"on_stick": return FFCondition.Type.ON_STICK
	return FFCondition.Type.ON_COMPLETE

static func _input_mode_to_str(v: int) -> String:
	match v:
		FFCondition.InputMode.ANY_PRESSED: return "any_pressed"
		FFCondition.InputMode.ANY_RELEASED: return "any_released"
		FFCondition.InputMode.ALL_RELEASED: return "all_released"
		FFCondition.InputMode.ANY_HELD: return "any_held"
		FFCondition.InputMode.NONE_HELD: return "none_held"
	return "any_pressed"

static func _input_mode_from_str(s: String) -> int:
	match s:
		"any_released": return FFCondition.InputMode.ANY_RELEASED
		"all_released": return FFCondition.InputMode.ALL_RELEASED
		"any_held": return FFCondition.InputMode.ANY_HELD
		"none_held": return FFCondition.InputMode.NONE_HELD
	return FFCondition.InputMode.ANY_PRESSED

static func _stick_vs_to_str(v: int) -> String:
	return "velocity" if v == FFCondition.StickAngleVs.VELOCITY else "facing"

static func _stick_vs_from_str(s: String) -> int:
	return FFCondition.StickAngleVs.VELOCITY if s == "velocity" else FFCondition.StickAngleVs.FACING

static func _op_to_str(v: int) -> String:
	match v:
		FFCondition.Op.EQ: return "eq"
		FFCondition.Op.NE: return "ne"
		FFCondition.Op.GT: return "gt"
		FFCondition.Op.GE: return "ge"
		FFCondition.Op.LT: return "lt"
		FFCondition.Op.LE: return "le"
	return "eq"

static func _op_from_str(s: String) -> int:
	match s:
		"ne": return FFCondition.Op.NE
		"gt": return FFCondition.Op.GT
		"ge": return FFCondition.Op.GE
		"lt": return FFCondition.Op.LT
		"le": return FFCondition.Op.LE
	return FFCondition.Op.EQ

static func _ptype_to_str(v: int) -> String:
	match v:
		FFParameter.PType.BOOL: return "bool"
		FFParameter.PType.INT: return "int"
		FFParameter.PType.FLOAT: return "float"
		FFParameter.PType.STRING: return "string"
	return "float"

static func _ptype_from_str(s: String) -> int:
	match s:
		"bool": return FFParameter.PType.BOOL
		"int": return FFParameter.PType.INT
		"string": return FFParameter.PType.STRING
	return FFParameter.PType.FLOAT

static func _trigger_to_str(v: int) -> String:
	match v:
		FFStateEvent.Trigger.ON_ENTER: return "on_enter"
		FFStateEvent.Trigger.ON_EXIT: return "on_exit"
		FFStateEvent.Trigger.ON_FRAME: return "on_frame"
	return "on_enter"

static func _trigger_from_str(s: String) -> int:
	match s:
		"on_exit": return FFStateEvent.Trigger.ON_EXIT
		"on_frame": return FFStateEvent.Trigger.ON_FRAME
	return FFStateEvent.Trigger.ON_ENTER

static func _momentum_to_str(v: int) -> String:
	return "preserve" if v == FFTransition.Momentum.PRESERVE else "cut"

static func _momentum_from_str(s: String) -> int:
	return FFTransition.Momentum.PRESERVE if s == "preserve" else FFTransition.Momentum.CUT

# --- G-4 param assigns (Rust `ParamAssign`, serde tag "op") ---

## ParamValue is untagged: bool/int/float/String pass through, Vector3 as [x, y, z].
static func _variant_to_json(v: Variant) -> Variant:
	if v is Vector3:
		return [v.x, v.y, v.z]
	return v

static func _json_to_variant(v: Variant) -> Variant:
	if v is Array and v.size() == 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	return v

static func _param_assign_to_dict(a: FFParamAssign) -> Dictionary:
	if a.kind == FFParamAssign.Kind.COUNTDOWN:
		return {"op": "countdown", "name": a.name, "ticks": a.ticks}
	return {"op": "set", "name": a.name, "value": _variant_to_json(a.value)}

static func _dict_to_param_assign(d: Dictionary) -> FFParamAssign:
	var a := FFParamAssign.new()
	if String(d.get("op", "set")) == "countdown":
		a.kind = FFParamAssign.Kind.COUNTDOWN
		a.ticks = int(d.get("ticks", 0))
	else:
		a.kind = FFParamAssign.Kind.SET
	a.name = String(d.get("name", ""))
	a.value = _json_to_variant(d.get("value", 0.0))
	return a

static func _assigns_to_json(assigns: Array[FFParamAssign]) -> Array:
	var out := []
	for a in assigns:
		if a != null:
			out.append(_param_assign_to_dict(a))
	return out

static func _assigns_from_json(arr: Array) -> Array[FFParamAssign]:
	var out: Array[FFParamAssign] = []
	for e in arr:
		if e is Dictionary:
			out.append(_dict_to_param_assign(e))
	return out

# --- G-5 steer config (Rust `SteerConfig`, all fields serialized) ---

static func _face_mode_to_str(v: int) -> String:
	match v:
		FFSteerConfig.FaceMode.VELOCITY:
			return "velocity"
		FFSteerConfig.FaceMode.STICK:
			return "stick"
	return "keep"

static func _face_mode_from_str(s: String) -> int:
	match s:
		"velocity":
			return FFSteerConfig.FaceMode.VELOCITY
		"stick":
			return FFSteerConfig.FaceMode.STICK
	return FFSteerConfig.FaceMode.KEEP

static func _enter_vy_to_json(s: FFSteerConfig) -> Variant:
	match s.enter_vy:
		FFSteerConfig.EnterVy.SET:
			return {"set": s.enter_vy_value}
		FFSteerConfig.EnterVy.ADD:
			return {"add": s.enter_vy_value}
	return "keep"

static func _apply_enter_vy_json(s: FFSteerConfig, v: Variant) -> void:
	if v is Dictionary:
		if v.has("set"):
			s.enter_vy = FFSteerConfig.EnterVy.SET
			s.enter_vy_value = float(v["set"])
		elif v.has("add"):
			s.enter_vy = FFSteerConfig.EnterVy.ADD
			s.enter_vy_value = float(v["add"])
		else:
			s.enter_vy = FFSteerConfig.EnterVy.KEEP
	else:
		s.enter_vy = FFSteerConfig.EnterVy.KEEP

static func _turn_tier_to_dict(t: FFTurnTier) -> Dictionary:
	# Sparse, like the canonical files: the optional caps are omitted at
	# the core default (0.0). speed_max and cap_base are REQUIRED fields
	# in the Rust schema (no serde default) and are always written.
	var d := {
		"speed_max": t.speed_max,
		"cap_base": t.cap_base,
	}
	if t.cap_per_speed != 0.0:
		d["cap_per_speed"] = t.cap_per_speed
	if t.cap_per_radius != 0.0:
		d["cap_per_radius"] = t.cap_per_radius
	if t.cap_min != 0.0:
		d["cap_min"] = t.cap_min
	if t.cap_max != 0.0:
		d["cap_max"] = t.cap_max
	return d

static func _dict_to_turn_tier(d: Dictionary) -> FFTurnTier:
	var t := FFTurnTier.new()
	t.speed_max = float(d.get("speed_max", 0.0))
	t.cap_base = float(d.get("cap_base", 0.0))
	t.cap_per_speed = float(d.get("cap_per_speed", 0.0))
	t.cap_per_radius = float(d.get("cap_per_radius", 0.0))
	t.cap_min = float(d.get("cap_min", 0.0))
	t.cap_max = float(d.get("cap_max", 0.0))
	return t

static func steer_to_dict(s: FFSteerConfig) -> Dictionary:
	if s == null:
		return {}
	# Sparse, matching the canonical files and the core's serde defaults:
	# any field sitting at its SteerConfig::default() value is omitted.
	var d := {}
	if s.accel_forward != 0.0:
		d["accel_forward"] = s.accel_forward
	if s.accel_side != 0.0:
		d["accel_side"] = s.accel_side
	if s.accel_backward != 0.0:
		d["accel_backward"] = s.accel_backward
	if s.backward_until_zero:
		d["backward_until_zero"] = true
	if s.accel_along_velocity != 0.0:
		d["accel_along_velocity"] = s.accel_along_velocity
	if s.speed_cap != 0.0:
		d["speed_cap"] = s.speed_cap
	if s.speed_cap_per_radius != 0.0:
		d["speed_cap_per_radius"] = s.speed_cap_per_radius
	if s.speed_min != 0.0:
		d["speed_min"] = s.speed_min
	if s.enter_impact_speed != 0.0:
		d["enter_impact_speed"] = s.enter_impact_speed
	if s.decel_above_cap != 0.0:
		d["decel_above_cap"] = s.decel_above_cap
	if s.max_speed != 0.0:
		d["max_speed"] = s.max_speed
	if s.decay != 0.0:
		d["decay"] = s.decay
	if s.gravity != 0.0:
		d["gravity"] = s.gravity
	if s.terminal_velocity != 0.0:
		d["terminal_velocity"] = s.terminal_velocity
	if s.face_mode != FFSteerConfig.FaceMode.KEEP:
		d["face_mode"] = _face_mode_to_str(s.face_mode)
	var turn := {}
	if s.turn_deadzone_deg != 0.0:
		turn["deadzone_deg"] = s.turn_deadzone_deg
	if s.turn_accel_near_frac != 0.0:
		turn["accel_near_frac"] = s.turn_accel_near_frac
	if s.turn_accel_far_frac != 0.0:
		turn["accel_far_frac"] = s.turn_accel_far_frac
	if s.turn_far_angle_deg != 0.0:
		turn["far_angle_deg"] = s.turn_far_angle_deg
	if s.turn_max_angle_deg != 0.0:
		turn["max_angle_deg"] = s.turn_max_angle_deg
	if not s.turn_tiers.is_empty():
		var tiers := []
		for t in s.turn_tiers:
			if t != null:
				tiers.append(_turn_tier_to_dict(t))
		turn["tiers"] = tiers
	d["turn"] = turn
	if s.quickturn_angle_deg != 0.0:
		d["quickturn_angle_deg"] = s.quickturn_angle_deg
	if s.quickturn_rate_deg != 0.0:
		d["quickturn_rate_deg"] = s.quickturn_rate_deg
	if not s.enter_keep_horizontal:
		d["enter_keep_horizontal"] = false
	if s.enter_vy != FFSteerConfig.EnterVy.KEEP:
		d["enter_vy"] = _enter_vy_to_json(s)
	return d

static func dict_to_steer(v: Variant) -> FFSteerConfig:
	if v == null or not (v is Dictionary):
		return null
	var d: Dictionary = v
	var s := FFSteerConfig.new()
	s.accel_forward = float(d.get("accel_forward", 0.0))
	s.accel_side = float(d.get("accel_side", 0.0))
	s.accel_backward = float(d.get("accel_backward", 0.0))
	s.backward_until_zero = bool(d.get("backward_until_zero", false))
	s.accel_along_velocity = float(d.get("accel_along_velocity", 0.0))
	s.speed_cap = float(d.get("speed_cap", 0.0))
	s.speed_cap_per_radius = float(d.get("speed_cap_per_radius", 0.0))
	s.speed_min = float(d.get("speed_min", 0.0))
	s.enter_impact_speed = float(d.get("enter_impact_speed", 0.0))
	s.decel_above_cap = float(d.get("decel_above_cap", 0.0))
	s.max_speed = float(d.get("max_speed", 0.0))
	s.decay = float(d.get("decay", 0.0))
	s.gravity = float(d.get("gravity", 0.0))
	s.terminal_velocity = float(d.get("terminal_velocity", 0.0))
	s.face_mode = _face_mode_from_str(String(d.get("face_mode", "keep")))
	var turn: Dictionary = d.get("turn", {})
	s.turn_deadzone_deg = float(turn.get("deadzone_deg", 0.0))
	s.turn_accel_near_frac = float(turn.get("accel_near_frac", 0.0))
	s.turn_accel_far_frac = float(turn.get("accel_far_frac", 0.0))
	s.turn_far_angle_deg = float(turn.get("far_angle_deg", 0.0))
	s.turn_max_angle_deg = float(turn.get("max_angle_deg", 0.0))
	for td in turn.get("tiers", []):
		if td is Dictionary:
			s.turn_tiers.append(_dict_to_turn_tier(td))
	s.quickturn_angle_deg = float(d.get("quickturn_angle_deg", 0.0))
	s.quickturn_rate_deg = float(d.get("quickturn_rate_deg", 0.0))
	s.enter_keep_horizontal = bool(d.get("enter_keep_horizontal", true))
	_apply_enter_vy_json(s, d.get("enter_vy", "keep"))
	return s


# ------------------------------------------------------------------ values ---

static func _v3_to_arr(v: Vector3) -> Array:
	return [v.x, v.y, v.z]

static func _arr_to_v3(a: Array) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2])) if a.size() >= 3 else Vector3.ZERO

static func _v2_to_arr(v: Vector2) -> Array:
	return [v.x, v.y]

static func _arr_to_v2(a: Array) -> Vector2:
	return Vector2(float(a[0]), float(a[1])) if a.size() >= 2 else Vector2.ZERO

## ParamValue is untagged in JSON: the raw value passes through.
static func _variant_to_dict(v: Variant) -> Variant:
	return v

static func _dict_to_variant(d: Variant) -> Variant:
	return d

static func _curve_to_dict(c: Curve) -> Dictionary:
	var pts := []
	if c != null:
		for i in c.get_point_count():
			pts.append({
				"pos": [c.get_point_position(i).x, c.get_point_position(i).y],
				"left_tangent": c.get_point_left_tangent(i),
				"right_tangent": c.get_point_right_tangent(i),
			})
	return {
		"points": pts,
		"min_value": c.min_value if c != null else 0.0,
		"max_value": c.max_value if c != null else 1.0,
	}

static func _dict_to_curve(d: Dictionary) -> Curve:
	var c := Curve.new()
	c.min_value = float(d.get("min_value", 0.0))
	c.max_value = float(d.get("max_value", 1.0))
	for p in d.get("points", []):
		var pos: Array = p.get("pos", [0.0, 0.0])
		c.add_point(Vector2(float(pos[0]), float(pos[1])),
			float(p.get("left_tangent", 0.0)), float(p.get("right_tangent", 0.0)))
	return c

# ------------------------------------------------------------------ behavior ---

static func behavior_to_dict(bh: FrameBehavior) -> Dictionary:
	var machines := []
	for m in bh.sub_machines:
		if m != null:
			machines.append(machine_to_dict(m))
	var params := []
	for p in bh.parameters:
		if p != null:
			params.append(parameter_to_dict(p))
	var brows := []
	for r in bh.behavior_transitions:
		if r != null:
			brows.append(transition_to_dict(r))
	var d := {
		"behavior_name": bh.behavior_name,
		"sub_machines": machines,
		"parameters": params,
		"behavior_transitions": brows,
		"on_enter_event": bh.on_enter_event,
		"on_exit_event": bh.on_exit_event,
	}
	if bh.spin_detect != null:
		d["spin_detect"] = spin_to_dict(bh.spin_detect)
	return d

static func dict_to_behavior(d: Dictionary) -> FrameBehavior:
	var bh := FrameBehavior.new()
	bh.behavior_name = String(d.get("behavior_name", "Behavior"))
	for md in d.get("sub_machines", []):
		bh.sub_machines.append(dict_to_machine(md))
	for pd in d.get("parameters", []):
		bh.parameters.append(dict_to_parameter(pd))
	for rd in d.get("behavior_transitions", []):
		bh.behavior_transitions.append(dict_to_transition(rd))
	bh.on_enter_event = String(d.get("on_enter_event", ""))
	bh.on_exit_event = String(d.get("on_exit_event", ""))
	bh.spin_detect = dict_to_spin(d.get("spin_detect"))
	return bh

static func machine_to_dict(m: SubStateMachine) -> Dictionary:
	var states := []
	for s in m.states:
		if s != null:
			states.append(state_to_dict(s))
	var comments := []
	for c in m.editor_comments:
		if c != null:
			comments.append({
				"title": c.title,
				"position": _v2_to_arr(c.position),
				"size": _v2_to_arr(c.size),
				"tint": [c.tint.r, c.tint.g, c.tint.b, c.tint.a],
			})
	return {
		"machine_name": m.machine_name,
		"states": states,
		"entry_state_name": String(m.entry_state.state_name) if m.entry_state != null else "",
		"default_resp_floor": response_to_dict(m.default_resp_floor),
		"default_resp_ceiling": response_to_dict(m.default_resp_ceiling),
		"default_resp_wall": response_to_dict(m.default_resp_wall),
		"editor_comments": comments,
	}

static func dict_to_machine(d: Dictionary) -> SubStateMachine:
	var m := SubStateMachine.new()
	m.machine_name = String(d.get("machine_name", "Machine"))
	var by_name := {}
	for sd in d.get("states", []):
		var s := dict_to_state(sd)
		m.states.append(s)
		by_name[s.state_name] = s
	var entry_name := String(d.get("entry_state_name", ""))
	if by_name.has(entry_name):
		m.entry_state = by_name[entry_name]
	elif not m.states.is_empty():
		m.entry_state = m.states[0]
	m.default_resp_floor = dict_to_response(d.get("default_resp_floor"))
	m.default_resp_ceiling = dict_to_response(d.get("default_resp_ceiling"))
	m.default_resp_wall = dict_to_response(d.get("default_resp_wall"))
	for cd in d.get("editor_comments", []):
		var c := FFComment.new()
		c.title = String(cd.get("title", "Comment"))
		c.position = _arr_to_v2(cd.get("position", [0, 0]))
		c.size = _arr_to_v2(cd.get("size", [280, 160]))
		var tint: Array = cd.get("tint", [0.9, 0.8, 0.4, 1.0])
		c.tint = Color(float(tint[0]), float(tint[1]), float(tint[2]), float(tint[3]))
		m.editor_comments.append(c)
	return m

static func state_to_dict(s: FrameState) -> Dictionary:
	var transitions := []
	for r in s.transitions:
		if r != null:
			transitions.append(transition_to_dict(r))
	var events := []
	for e in s.events:
		if e != null:
			events.append(event_to_dict(e))
	var d := {
		"state_name": s.state_name,
		"displacement": s.displacement,
		"direction": _v3_to_arr(s.direction),
		"duration_frames": s.duration_frames,
		"direction_source": _dir_src_to_str(s.direction_source),
		"displacement_source": _disp_src_to_str(s.displacement_source),
		"restitution": s.restitution,
		"input_left": s.input_left,
		"input_right": s.input_right,
		"input_forward": s.input_forward,
		"input_back": s.input_back,
		"input_plane": _plane_to_str(s.input_plane),
		"input_deadzone": s.input_deadzone,
		"camera_relative": s.camera_relative,
		"input_turn_rate_deg": s.input_turn_rate_deg,
		"resp_floor": response_to_dict(s.resp_floor),
		"resp_ceiling": response_to_dict(s.resp_ceiling),
		"resp_wall": response_to_dict(s.resp_wall),
		"events": events,
		"transitions": transitions,
	}
	# The canonical files omit the core-default easing (empty curve,
	# 0..1) and a zero editor position; match that.
	if s.easing != null and not (s.easing.get_point_count() == 0
			and s.easing.min_value == 0.0 and s.easing.max_value == 1.0):
		d["easing"] = _curve_to_dict(s.easing)
	if s.editor_position != Vector2.ZERO:
		d["editor_position"] = _v2_to_arr(s.editor_position)
	# G-6/G-4/G-5: omit when empty so canonical JSON stays clean.
	if not s.logic.is_empty():
		d["logic"] = s.logic
	if not s.group_name.is_empty():
		d["group_name"] = s.group_name
	if not s.enter_params.is_empty():
		d["enter_params"] = _assigns_to_json(s.enter_params)
	if s.steer != null:
		d["steer"] = steer_to_dict(s.steer)
	return d

static func dict_to_state(d: Dictionary) -> FrameState:
	var s := FrameState.new()
	s.state_name = String(d.get("state_name", "State"))
	s.displacement = float(d.get("displacement", 0.0))
	s.direction = _arr_to_v3(d.get("direction", [0, 0, 0]))
	s.duration_frames = int(d.get("duration_frames", 1))
	s.easing = _dict_to_curve(d.get("easing", {}))
	s.direction_source = _dir_src_from_str(String(d.get("direction_source", "author")))
	s.displacement_source = _disp_src_from_str(String(d.get("displacement_source", "author")))
	s.restitution = float(d.get("restitution", 1.0))
	s.input_left = String(d.get("input_left", ""))
	s.input_right = String(d.get("input_right", ""))
	s.input_forward = String(d.get("input_forward", ""))
	s.input_back = String(d.get("input_back", ""))
	s.input_plane = _plane_from_str(String(d.get("input_plane", "xz")))
	s.input_deadzone = float(d.get("input_deadzone", 0.2))
	s.camera_relative = bool(d.get("camera_relative", false))
	s.input_turn_rate_deg = float(d.get("input_turn_rate_deg", 0.0))
	s.resp_floor = dict_to_response(d.get("resp_floor"))
	s.resp_ceiling = dict_to_response(d.get("resp_ceiling"))
	s.resp_wall = dict_to_response(d.get("resp_wall"))
	for ed in d.get("events", []):
		s.events.append(dict_to_event(ed))
	for rd in d.get("transitions", []):
		s.transitions.append(dict_to_transition(rd))
	s.editor_position = _arr_to_v2(d.get("editor_position", [0, 0]))
	s.logic = String(d.get("logic", ""))
	s.group_name = String(d.get("group_name", ""))
	s.enter_params = _assigns_from_json(d.get("enter_params", []))
	s.steer = dict_to_steer(d.get("steer"))
	return s

static func transition_to_dict(r: FFTransition) -> Dictionary:
	var d := {
		"condition": condition_to_dict(r.condition),
		"target_state_name": String(r.target_state_name),
		"target_behavior_name": r.target_behavior.behavior_name if r.target_behavior != null else "",
		"momentum": _momentum_to_str(r.momentum),
		"blend_frames": r.blend_frames,
		"fire_event": r.fire_event,
		"silent": r.silent,
	}
	if not r.on_fire_params.is_empty():
		d["on_fire_params"] = _assigns_to_json(r.on_fire_params)
	if not r.source_tag.is_empty():
		d["source_tag"] = r.source_tag
	return d

static func dict_to_transition(d: Dictionary) -> FFTransition:
	var r := FFTransition.new()
	r.condition = dict_to_condition(d.get("condition", {}))
	r.target_state_name = String(d.get("target_state_name", ""))
	# Note: target_behavior is a Resource ref; JSON stores the name only.
	# The editor resolves it against open behaviors on load.
	r.target_behavior_name = String(d.get("target_behavior_name", ""))
	r.momentum = _momentum_from_str(String(d.get("momentum", "cut")))
	r.blend_frames = int(d.get("blend_frames", 3))
	r.fire_event = String(d.get("fire_event", ""))
	r.silent = bool(d.get("silent", false))
	r.on_fire_params = _assigns_from_json(d.get("on_fire_params", []))
	r.source_tag = String(d.get("source_tag", ""))
	return r

static func condition_to_dict(c: FFCondition) -> Dictionary:
	if c == null:
		return {"type": "on_complete"}
	var actions := []
	for a in c.input_actions:
		actions.append(String(a))
	var d := {
		"type": _cond_type_to_str(c.type),
		"input_actions": actions,
		"input_mode": _input_mode_to_str(c.input_mode),
		"param_name": c.param_name,
		"param_op": _op_to_str(c.param_op),
		"param_value": _variant_to_dict(c.param_value),
		"event_name": c.event_name,
		"target_machine_name": String(c.target_machine_name),
		"target_state_name": String(c.target_state_name),
		"custom_name": String(c.custom_name),
	}
	# G-1/G-2 + composites: omit at core defaults so canonical JSON
	# stays clean (same convention as on_fire_params / enter_params).
	if c.buffer_ticks != 0:
		d["buffer_ticks"] = c.buffer_ticks
	if c.stick_radius_min != 0.0:
		d["stick_radius_min"] = c.stick_radius_min
	if c.stick_radius_max != FFCondition.STICK_RADIUS_MAX_DEFAULT:
		d["stick_radius_max"] = c.stick_radius_max
	if c.stick_angle_vs != FFCondition.StickAngleVs.FACING:
		d["stick_angle_vs"] = _stick_vs_to_str(c.stick_angle_vs)
	if c.stick_angle_min_deg != 0.0:
		d["stick_angle_min_deg"] = c.stick_angle_min_deg
	if c.stick_angle_max_deg != 180.0:
		d["stick_angle_max_deg"] = c.stick_angle_max_deg
	if not c.all_of.is_empty():
		var kids := []
		for k in c.all_of:
			kids.append(condition_to_dict(k))
		d["all_of"] = kids
	if not c.any_of.is_empty():
		var kids := []
		for k in c.any_of:
			kids.append(condition_to_dict(k))
		d["any_of"] = kids
	return d

static func dict_to_condition(d: Dictionary) -> FFCondition:
	var c := FFCondition.new()
	c.type = _cond_type_from_str(String(d.get("type", "on_complete")))
	var actions := PackedStringArray()
	for a in d.get("input_actions", []):
		actions.append(String(a))
	c.input_actions = actions
	c.input_mode = _input_mode_from_str(String(d.get("input_mode", "any_pressed")))
	c.buffer_ticks = int(d.get("buffer_ticks", 0))
	c.param_name = String(d.get("param_name", ""))
	c.param_op = _op_from_str(String(d.get("param_op", "eq")))
	c.param_value = _dict_to_variant(d.get("param_value", 0.0))
	c.event_name = String(d.get("event_name", ""))
	c.target_machine_name = String(d.get("target_machine_name", ""))
	c.target_state_name = String(d.get("target_state_name", ""))
	c.custom_name = String(d.get("custom_name", ""))
	c.stick_radius_min = float(d.get("stick_radius_min", 0.0))
	c.stick_radius_max = float(d.get("stick_radius_max", FFCondition.STICK_RADIUS_MAX_DEFAULT))
	c.stick_angle_vs = _stick_vs_from_str(String(d.get("stick_angle_vs", "facing")))
	c.stick_angle_min_deg = float(d.get("stick_angle_min_deg", 0.0))
	c.stick_angle_max_deg = float(d.get("stick_angle_max_deg", 180.0))
	for kd in d.get("all_of", []):
		if kd is Dictionary:
			c.all_of.append(dict_to_condition(kd))
	for kd in d.get("any_of", []):
		if kd is Dictionary:
			c.any_of.append(dict_to_condition(kd))
	return c

static func parameter_to_dict(p: FFParameter) -> Dictionary:
	return {
		"name": p.name,
		"type": _ptype_to_str(p.ptype),
		"default_value": _variant_to_dict(p.default_value),
	}

static func dict_to_parameter(d: Dictionary) -> FFParameter:
	var p := FFParameter.new()
	p.name = String(d.get("name", ""))
	# The Rust schema key is "type"; "ptype" is accepted for files the
	# pre-1:1 editor wrote.
	p.ptype = _ptype_from_str(String(d.get("type", d.get("ptype", "float"))))
	p.default_value = _dict_to_variant(d.get("default_value", 0.0))
	return p

static func spin_to_dict(s: FFSpinDetect) -> Variant:
	if s == null:
		return null
	return {
		"min_frames": s.min_frames,
		"max_frames": s.max_frames,
		"angle_tolerance_deg": s.angle_tolerance_deg,
		"min_area": s.min_area,
		"buffer_ticks": s.buffer_ticks,
		"output_param": s.output_param,
	}

static func dict_to_spin(v: Variant) -> FFSpinDetect:
	if v == null or not (v is Dictionary):
		return null
	var s := FFSpinDetect.new()
	s.min_frames = int(v.get("min_frames", 31))
	s.max_frames = int(v.get("max_frames", 70))
	s.angle_tolerance_deg = float(v.get("angle_tolerance_deg", 45.57))
	s.min_area = float(v.get("min_area", 5.0))
	s.buffer_ticks = int(v.get("buffer_ticks", 30))
	s.output_param = String(v.get("output_param", "spin.valid"))
	return s

static func response_to_dict(r: FFResponse) -> Variant:
	if r == null:
		return null
	return {
		"target_state_name": String(r.target_state_name),
		"target_behavior_name": r.target_behavior.behavior_name if r.target_behavior != null else "",
		"min_incoming_speed": r.min_incoming_speed,
		"rearm_ticks": r.rearm_ticks,
	}

static func dict_to_response(d: Variant) -> FFResponse:
	if d == null or not (d is Dictionary):
		return null
	var r := FFResponse.new()
	r.target_state_name = String(d.get("target_state_name", ""))
	r.target_behavior_name = String(d.get("target_behavior_name", ""))
	r.min_incoming_speed = float(d.get("min_incoming_speed", 0.0))
	r.rearm_ticks = int(d.get("rearm_ticks", 3))
	return r

static func event_to_dict(e: FFStateEvent) -> Dictionary:
	return {
		"event_name": e.event_name,
		"trigger": _trigger_to_str(e.trigger),
		"frame": e.frame,
	}

static func dict_to_event(d: Dictionary) -> FFStateEvent:
	var e := FFStateEvent.new()
	e.event_name = String(d.get("event_name", ""))
	e.trigger = _trigger_from_str(String(d.get("trigger", "on_enter")))
	e.frame = int(d.get("frame", 0))
	return e

# ------------------------------------------------------------------ file io ---

static func save_behavior(bh: FrameBehavior, path: String) -> int:
	var json := JSON.stringify(behavior_to_dict(bh), "\t")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(json)
	f.close()
	return OK

static func load_behavior(path: String) -> FrameBehavior:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		return null
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return null
	return dict_to_behavior(parsed)
