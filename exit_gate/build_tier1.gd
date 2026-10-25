extends SceneTree
## Tier 1 behavior builders. Each --only <name> builds one .tres into
## exit_gate/behaviors/. Run: godot --headless --path . --script
## res://exit_gate/build_tier1.gd -- --only walk
##
## Conventions: interactive behaviors read ff_left/ff_right/ff_fwd/ff_back
## (analog), ff_jump (A), ff_crouch (Z), ff_attack (B). The gate harness
## drives these from the oracle CSV. Sim stick_y+ = +Z world = ff_back.

const OUT_DIR := "res://exit_gate/behaviors/"
const ACTIONS := ["ff_left", "ff_right", "ff_fwd", "ff_back"]
## Sim units (cm) -> Godot meters. All authored displacements are converted.
const SIM_TO_M := 0.01


func _init() -> void:
	var args := _parse_args()
	var only: String = args.get("--only", "all")
	var builders := {"walk": _build_walk, "move": _build_move, "jump_fwd": _build_jump_fwd, "double_jump": _build_double_jump, "long_jump": _build_long_jump, "ground_pound": _build_ground_pound}
	if only == "all":
		for k in builders.keys():
			builders[k].call()
	else:
		builders[only].call()
	quit()


# ------------------------------------------------------------------ move ---
## Full locomotion: walk + jump. Two sub-machines (horizontal/vertical).
## jump_vy: takeoff vy (42 = neutral, 50 = from walk at 32).

func _build_move() -> void:
	_build_walk_into("move.tres", 42.0)


func _build_long_jump() -> void:
	# Full walk locomotion + long jump vertical.
	_build_walk_into("long_jump.tres", 0.0)
	var bh: FrameBehavior = load("res://exit_gate/behaviors/long_jump.tres")
	var loco: SubStateMachine = bh.sub_machines[0]

	var vert := SubStateMachine.new()
	vert.machine_name = "Vertical"
	# Long jump: vy=30, gravity -2 (floatier). Measured arc.
	var lj_rise := [30.0, 28.0, 26.0, 24.0, 22.0, 20.0, 18.0, 16.0, 14.0, 12.0, 10.0, 8.0, 6.0, 4.0, 2.0, 0.0]
	var lj_fall := [2.0, 4.0, 6.0, 8.0, 10.0, 12.0, 14.0, 16.0, 18.0, 20.0, 22.0, 24.0, 26.0, 28.0, 30.0]
	var ground := _state("Ground", 1, 0.0, Vector3.ZERO)
	var rise := _arc_state("LongRise", lj_rise, Vector3.UP)
	var fall := _arc_state("LongFall", lj_fall, Vector3.DOWN)
	# Long jump from Ground on ff_jump (Z+A in the scenario; A edge suffices here).
	ground.transitions = [_jump_input_row_to("LongRise"), _complete_row(ground)]
	rise.transitions = [_complete_row(fall)]
	fall.transitions = [_complete_row(ground)]
	vert.states = [ground, rise, fall]
	vert.entry_state = ground

	# LongAir: 30f air phase, measured per-frame deltas (oracle frames 40-69).
	var air_vals := [45.1819, 46.3318, 47.4817, 47.6318, 47.7817, 47.9317,
		48.082, 48.232, 48.3818, 48.5317, 48.6817, 48.832, 48.9819, 49.1319,
		49.2817, 49.4316, 49.5821, 49.7319, 49.8818, 50.0318, 50.1816, 50.3321,
		50.4819, 50.6318, 50.782, 50.9317, 51.082, 51.2314, 51.3819, 51.5322]
	var air := _fitted_state("LongAir", air_vals)
	# LongLand: 6f landing slide (oracle frames 70-75).
	var land := _fitted_state("LongLand", [51.6816, 51.6817, 50.6484, 49.6348, 48.6426, 47.6699])
	# LongRollout: 15f walk-speed decay (oracle frames 76-90).
	var roll := _fitted_state("LongRollout", [45.7158, 44.7157, 43.716, 42.7158,
		41.7158, 40.7158, 39.7158, 38.7158, 37.7159, 36.7158, 35.7158, 34.7158,
		33.7158, 32.7159, 31.7158])
	# LongCrouch: 1f Z-press wind-up (oracle frame 39). The sim stays in walk
	# for the Z frame and only leaves the ground on the A frame.
	var crouch := _fitted_state("LongCrouch", [29.3545])

	air.transitions = [_complete_row_by_name("LongLand")]
	land.transitions = [_complete_row_by_name("LongRollout")]
	roll.transitions = [_complete_row_by_name("WalkCruise")]
	crouch.transitions = [_jump_input_row_to("LongAir"), _complete_row_by_name("WalkCruise")]

	# Grounded loco states -> LongAir on the same ff_jump edge the vertical
	# uses; -> LongCrouch on the ff_crouch edge (Z before A). The jump row
	# goes first so Z+A on the same tick still long-jumps.
	# (The old ON_STATE coordination lagged up to 3 ticks when the jump
	# fired from WalkAccel, which had no On-State row.)
	var crouch_row := FFTransition.new()
	var cc := FFCondition.new()
	cc.type = FFCondition.Type.ON_INPUT
	var cpa := PackedStringArray()
	cpa.append("ff_crouch")
	cc.input_actions = cpa
	cc.input_mode = FFCondition.InputMode.ANY_PRESSED
	crouch_row.condition = cc
	crouch_row.target_state_name = &"LongCrouch"
	for s in loco.states:
		if s.state_name == "WalkAccel" or s.state_name == "WalkCruise":
			var trs: Array[FFTransition] = [_jump_input_row_to("LongAir"), crouch_row]
			for t in s.transitions:
				trs.append(t)
			s.transitions = trs
	loco.states.append(air)
	loco.states.append(land)
	loco.states.append(roll)
	loco.states.append(crouch)

	bh.sub_machines = [vert, loco]
	_save(bh, "long_jump.tres")


## Fitted horizontal state: INPUT direction, AUTHOR displacement from measured
## per-frame sim-unit values.
func _fitted_state(sname: String, vals: Array) -> FrameState:
	var total := 0.0
	for x in vals:
		total += float(x)
	var s := _state(sname, vals.size(), total * SIM_TO_M, Vector3.ZERO)
	s.direction_source = FrameState.DirectionSource.INPUT
	_set_input_actions(s)
	s.displacement_source = FrameState.DisplacementSource.AUTHOR
	s.easing = _fit_curve(vals)
	return s


func _build_ground_pound() -> void:
	var bh := FrameBehavior.new()
	bh.behavior_name = "GroundPound"
	var vert := SubStateMachine.new()
	vert.machine_name = "Vertical"

	var jump_arc := _jump_arc(42.0)
	var ground := _state("Ground", 1, 0.0, Vector3.ZERO)
	var j_rise := _arc_state("JumpRise", jump_arc[0], Vector3.UP)
	var j_fall := _arc_state("JumpFall", jump_arc[1], Vector3.DOWN)
	# Pound rise: 10f, [20, 18, ..., 2].
	var pound_rise_vals := [20.0, 18.0, 16.0, 14.0, 12.0, 10.0, 8.0, 6.0, 4.0, 2.0]
	var p_rise := _arc_state("PoundRise", pound_rise_vals, Vector3.UP)
	# Pound slam: [-50, -54, -58, -62, -66] (gravity -4 from -50).
	var pound_slam_vals := [50.0, 54.0, 58.0, 62.0, 66.0]
	var p_slam := _arc_state("PoundSlam", pound_slam_vals, Vector3.DOWN)
	# Hover: 5f zero between rise and slam.
	var p_hover := _state("PoundHover", 5, 0.0, Vector3.ZERO)
	# Landing impact: 1f, -12.
	var p_land_vals := [12.0]
	var p_land := _arc_state("PoundLand", p_land_vals, Vector3.DOWN)

	ground.transitions = [_jump_input_row_to("JumpRise"), _complete_row(ground)]
	# Z (ff_crouch) in mid-air -> ground pound.
	var pound_row := FFTransition.new()
	var pc := FFCondition.new()
	pc.type = FFCondition.Type.ON_INPUT
	var ppa := PackedStringArray()
	ppa.append("ff_crouch")
	pc.input_actions = ppa
	pc.input_mode = FFCondition.InputMode.ANY_PRESSED
	pound_row.condition = pc
	pound_row.target_state_name = &"PoundRise"
	j_rise.transitions = [_complete_row(j_fall), pound_row]
	j_fall.transitions = [pound_row, _complete_row(ground)]
	p_rise.transitions = [_complete_row(p_hover)]
	p_hover.transitions = [_complete_row(p_slam)]
	p_slam.transitions = [_complete_row(p_land)]
	p_land.transitions = [_complete_row(ground)]

	vert.states = [ground, j_rise, j_fall, p_rise, p_hover, p_slam, p_land]
	vert.entry_state = ground
	bh.sub_machines = [vert]
	_save(bh, "ground_pound.tres")


func _build_double_jump() -> void:
	var bh := FrameBehavior.new()
	bh.behavior_name = "DoubleJump"
	var vert := SubStateMachine.new()
	vert.machine_name = "Vertical"

	# Single (vy=42), double (vy=52), triple (vy=50).
	var s_arc := _jump_arc(42.0)
	var d_arc := _jump_arc(52.0)
	var t_arc := _jump_arc(50.0)

	var ground := _state("Ground", 1, 0.0, Vector3.ZERO)
	var s_rise_s := _arc_state("JumpRise", s_arc[0], Vector3.UP)
	var s_fall_s := _arc_state("JumpFall", s_arc[1], Vector3.DOWN)
	var land1 := _state("LandFromJump", 5, 0.0, Vector3.ZERO)
	var d_rise_s := _arc_state("DoubleRise", d_arc[0], Vector3.UP)
	var d_fall_s := _arc_state("DoubleFall", d_arc[1], Vector3.DOWN)
	var land2 := _state("LandFromDouble", 5, 0.0, Vector3.ZERO)
	var t_rise_s := _arc_state("TripleRise", t_arc[0], Vector3.UP)
	var t_fall_s := _arc_state("TripleFall", t_arc[1], Vector3.DOWN)

	ground.transitions = [_jump_input_row_to("JumpRise"), _complete_row(ground)]
	s_rise_s.transitions = [_complete_row(s_fall_s)]
	s_fall_s.transitions = [_complete_row(land1)]
	land1.transitions = [_jump_input_row_to("DoubleRise"), _complete_row(ground)]
	d_rise_s.transitions = [_complete_row(d_fall_s)]
	d_fall_s.transitions = [_complete_row(land2)]
	land2.transitions = [_jump_input_row_to("TripleRise"), _complete_row(ground)]
	t_rise_s.transitions = [_complete_row(t_fall_s)]
	t_fall_s.transitions = [_complete_row(ground)]

	vert.states = [ground, s_rise_s, s_fall_s, land1, d_rise_s, d_fall_s, land2, t_rise_s, t_fall_s]
	vert.entry_state = ground
	bh.sub_machines = [vert]
	_save(bh, "double_jump.tres")


## Jump arc: vy, vy-4, vy-8, ... down to -vy (sim steps through zero).
## Split into rise (v >= 0) and fall (v < 0) parts.
func _jump_arc(vy: float) -> Array:
	var rise_part := []
	var fall_part := []
	var v := vy
	while v >= -vy:
		if v >= 0.0:
			rise_part.append(v)
		else:
			fall_part.append(v)
		v -= 4.0
	return [rise_part, fall_part]


func _arc_state(sname: String, vals: Array, dir: Vector3) -> FrameState:
	var abs_vals := []
	var total := 0.0
	for x in vals:
		var ax: float = absf(float(x))
		abs_vals.append(ax)
		total += ax
	var s := _state(sname, abs_vals.size(), total * SIM_TO_M, dir)
	s.easing = _fit_curve(abs_vals)
	return s


func _jump_input_row_to(target: String) -> FFTransition:
	var row := FFTransition.new()
	var c := FFCondition.new()
	c.type = FFCondition.Type.ON_INPUT
	var pa := PackedStringArray()
	pa.append("ff_jump")
	c.input_actions = pa
	c.input_mode = FFCondition.InputMode.ANY_PRESSED
	row.condition = c
	row.target_state_name = StringName(target)
	return row


func _build_jump_fwd() -> void:
	# Forward jump with exact measured profiles (vy=48.975, impact landing).
	var bh := FrameBehavior.new()
	bh.behavior_name = "JumpFwd"
	# Build locomotion via walk_into, then replace vertical.
	_build_walk_into("jump_fwd.tres", 0.0)
	bh = load("res://exit_gate/behaviors/jump_fwd.tres")

	var vert := SubStateMachine.new()
	vert.machine_name = "Vertical"
	# Measured (frames 30-42 rise, 43-55 fall with impact).
	var rise_vals := [48.97, 44.97, 40.97, 36.97, 32.97, 28.97, 24.97, 20.97, 16.97, 12.97, 8.97, 4.97, 0.97]
	var fall_vals := [3.03, 7.03, 11.03, 15.03, 19.03, 23.03, 27.03, 31.03, 35.03, 39.03, 43.03, 47.03, 24.37]
	var rise_total := 0.0
	for x in rise_vals:
		rise_total += x
	var fall_total := 0.0
	for x in fall_vals:
		fall_total += x
	var ground := _state("Ground", 1, 0.0, Vector3.ZERO)
	var rise := _state("JumpRise", rise_vals.size(), rise_total * SIM_TO_M, Vector3.UP)
	rise.easing = _fit_curve(rise_vals)
	var fall := _state("JumpFall", fall_vals.size(), fall_total * SIM_TO_M, Vector3.DOWN)
	fall.easing = _fit_curve(fall_vals)
	ground.transitions = [_jump_input_row(), _complete_row(ground)] as Array[FFTransition]
	rise.transitions = [_complete_row(fall)] as Array[FFTransition]
	fall.transitions = [_complete_row(ground)] as Array[FFTransition]
	vert.states = [ground, rise, fall]
	vert.entry_state = ground

	# Replace machines: Vertical first, then Locomotion with AirMove.
	var loco: SubStateMachine = bh.sub_machines[0]
	_add_airmove(loco, vert)
	bh.sub_machines = [vert, loco]
	_save(bh, "jump_fwd.tres")


func _build_walk() -> void:
	_build_walk_into("walk.tres", 0.0)


func _build_locomotion() -> SubStateMachine:
	var profile := _walk_profile()
	var accel_n := 0
	for i in profile.size():
		if float(profile[i]) >= 31.99:
			accel_n = i + 1
			break
	var accel_vals := profile.slice(0, accel_n)
	var cruise_vals := profile.slice(accel_n, accel_n + 128)
	var accel_total := 0.0
	for v in accel_vals:
		accel_total += float(v)
	var cruise_total := 0.0
	for v in cruise_vals:
		cruise_total += float(v)

	var loco := SubStateMachine.new()
	loco.machine_name = "Locomotion"

	var idle := _state("Idle", 1, 0.0, Vector3.ZERO)
	var accel := _state("WalkAccel", accel_n, accel_total * SIM_TO_M, Vector3.ZERO)
	accel.direction_source = FrameState.DirectionSource.INPUT
	_set_input_actions(accel)
	accel.easing = _fit_curve(accel_vals)
	var cruise := _state("WalkCruise", cruise_vals.size(), cruise_total * SIM_TO_M, Vector3.ZERO)
	cruise.direction_source = FrameState.DirectionSource.INPUT
	_set_input_actions(cruise)
	cruise.easing = _fit_curve(cruise_vals)
	var brake := _state("WalkBrake", 8, 0.0, Vector3.ZERO)
	brake.direction_source = FrameState.DirectionSource.ENTRY
	brake.displacement_source = FrameState.DisplacementSource.AUTHOR
	var brake_vals := [27.629, 23.629, 19.629, 15.629, 11.629, 7.629, 3.629, 0.0]
	var brake_total := 0.0
	for v in brake_vals:
		brake_total += v
	brake.displacement = brake_total * SIM_TO_M
	brake.easing = _fit_curve(brake_vals)

	idle.transitions = [_input_row(ACTIONS, FFCondition.InputMode.ANY_PRESSED, accel)]
	accel.transitions = [
		_input_row(ACTIONS, FFCondition.InputMode.ALL_RELEASED, brake),
		_complete_row(cruise),
	]
	cruise.transitions = [
		_input_row(ACTIONS, FFCondition.InputMode.ALL_RELEASED, brake),
		_complete_row(cruise),
	]
	brake.transitions = [_complete_row(idle)]

	loco.states = [idle, accel, cruise, brake]
	loco.entry_state = idle
	return loco


func _build_walk_into(fname: String, jump_vy: float) -> void:
	var bh := FrameBehavior.new()
	bh.behavior_name = "Move"
	var loco := _build_locomotion()

	if jump_vy > 0.0:
		var vert := _build_vertical(jump_vy)
		# Vertical first: Locomotion's On-State rows see the updated state.
		bh.sub_machines = [vert, loco]
		if fname == "jump_fwd.tres":
			_add_airmove(loco, vert)
	else:
		bh.sub_machines = [loco]
	_save(bh, fname)


## Vertical machine: Ground / JumpRise / JumpFall for a given takeoff vy.
func _build_vertical(jump_vy: float) -> SubStateMachine:
	var vert := SubStateMachine.new()
	vert.machine_name = "Vertical"
	# Rise: vy, vy-4, ... until <= 0. Fall: mirror.
	var rise_vals := []
	var v := jump_vy
	while v > 0.0:
		rise_vals.append(v)
		v -= 4.0
	var fall_vals := []
	for rv in rise_vals:
		fall_vals.append(rv)
	fall_vals.reverse()
	var rise_total := 0.0
	for x in rise_vals:
		rise_total += x
	var fall_total := 0.0
	for x in fall_vals:
		fall_total += x
	print("jump vy=%.1f: rise %d frames, fall %d frames" % [jump_vy, rise_vals.size(), fall_vals.size()])

	var ground := _state("Ground", 1, 0.0, Vector3.ZERO)
	var rise := _state("JumpRise", rise_vals.size(), rise_total * SIM_TO_M, Vector3.UP)
	rise.easing = _fit_curve(rise_vals)
	var fall := _state("JumpFall", fall_vals.size(), fall_total * SIM_TO_M, Vector3.DOWN)
	fall.easing = _fit_curve(fall_vals)

	# A-release velocity cut: on early button release during rise, the sim
	# cuts upward velocity to ~1/4. Model as JumpRiseCut (up) -> JumpFallCut (down).
	# From oracle (vy=42): release on frame N, frame N+1 is normal (vy-4),
	# frame N+2 cuts to (vy-4)/4, then gravity -4 until ground.
	# The first rise frame (vy) already executed before the transition.
	var cut_rise_vals := []
	var cv := jump_vy - 4.0
	cut_rise_vals.append(cv)  # normal frame after release
	cv = cv / 4.0  # the cut
	while cv > 0.0:
		cut_rise_vals.append(cv)
		cv -= 4.0
	var cut_rise_total := 0.0
	for x in cut_rise_vals:
		cut_rise_total += x
	var rise_cut := _state("JumpRiseCut", cut_rise_vals.size(), cut_rise_total * SIM_TO_M, Vector3.UP)
	rise_cut.easing = _fit_curve(cut_rise_vals)

	# Cut fall: from apex (negative) to ground. Values are positive with DOWN dir.
	var cut_fall_vals := []
	cv = 2.5  # first fall frame from oracle (vy=42); scale for other vy
	# Scale factor: cut apex is proportional to jump_vy
	var scale := jump_vy / 42.0
	cut_fall_vals = [2.5 * scale, 6.5 * scale, 10.5 * scale, 14.5 * scale, 18.5 * scale, 22.5 * scale]
	# Last frame lands exactly: total must bring us from (vy + cut_rise_total) to 0
	var fall_sum := 0.0
	for x in cut_fall_vals:
		fall_sum += x
	var remaining := jump_vy + cut_rise_total - fall_sum
	cut_fall_vals.append(remaining)  # final landing frame
	var cut_fall_total := 0.0
	for x in cut_fall_vals:
		cut_fall_total += x
	var fall_cut := _state("JumpFallCut", cut_fall_vals.size(), cut_fall_total * SIM_TO_M, Vector3.DOWN)
	fall_cut.easing = _fit_curve(cut_fall_vals)

	ground.transitions = [_jump_input_row(), _complete_row(ground)]
	rise.transitions = [_jump_release_row_to("JumpRiseCut"), _complete_row(fall)]
	rise_cut.transitions = [_complete_row(fall_cut)]
	fall_cut.transitions = [_complete_row(ground)]
	fall.transitions = [_complete_row(ground)]

	vert.states = [ground, rise, rise_cut, fall_cut, fall]
	vert.entry_state = ground
	return vert


func _jump_input_row() -> FFTransition:
	var row := FFTransition.new()
	var c := FFCondition.new()
	c.type = FFCondition.Type.ON_INPUT
	var pa := PackedStringArray()
	pa.append("ff_jump")
	c.input_actions = pa
	c.input_mode = FFCondition.InputMode.ANY_PRESSED
	row.condition = c
	row.target_state_name = &"JumpRise"
	return row


func _jump_release_row_to(target: String) -> FFTransition:
	var row := FFTransition.new()
	var c := FFCondition.new()
	c.type = FFCondition.Type.ON_INPUT
	var pa := PackedStringArray()
	pa.append("ff_jump")
	c.input_actions = pa
	c.input_mode = FFCondition.InputMode.ANY_RELEASED
	row.condition = c
	row.target_state_name = StringName(target)
	return row


## AirMove for the forward jump: fitted horizontal profile, coordinated
## with the Vertical machine via On State. Includes landing skid.
func _add_airmove(loco: SubStateMachine, vert: SubStateMachine) -> void:
	# Measured air horizontal (frames 30-55 of jump_forward_held, last=impact).
	var air_vals := [23.47, 24.62, 25.77, 26.92, 28.07, 29.22, 30.37, 31.52,
		31.67, 31.82, 31.97, 32.12, 32.27, 32.42, 32.57, 32.72, 32.87,
		33.02, 33.17, 33.32, 33.47, 33.62, 33.77, 33.92, 34.07, 17.11]
	var air_total := 0.0
	for v in air_vals:
		air_total += v
	var air := _state("AirMove", air_vals.size(), air_total * SIM_TO_M, Vector3.ZERO)
	air.direction_source = FrameState.DirectionSource.INPUT
	_set_input_actions(air)
	air.easing = _fit_curve(air_vals)

	# Landing skid (frames 56-59).
	var land_vals := [34.22, 33.54, 32.86, 31.21]
	var land_total := 0.0
	for v in land_vals:
		land_total += v
	var land := _state("Land", land_vals.size(), land_total * SIM_TO_M, Vector3.ZERO)
	land.direction_source = FrameState.DirectionSource.ENTRY
	land.displacement_source = FrameState.DisplacementSource.AUTHOR
	land.easing = _fit_curve(land_vals)

	# Locomotion -> AirMove when Vertical is airborne.
	for s in loco.states:
		if s.state_name == "AirMove" or s.state_name == "Land":
			continue
		var row := FFTransition.new()
		var c := FFCondition.new()
		c.type = FFCondition.Type.ON_STATE
		c.target_machine_name = &"Vertical"
		c.target_state_name = &"JumpRise"
		row.condition = c
		row.target_state_name = &"AirMove"
		var row2 := FFTransition.new()
		var c2 := FFCondition.new()
		c2.type = FFCondition.Type.ON_STATE
		c2.target_machine_name = &"Vertical"
		c2.target_state_name = &"JumpFall"
		row2.condition = c2
		row2.target_state_name = &"AirMove"
		# Prepend: airborne check beats walk rows.
		var trs: Array[FFTransition] = [row, row2]
		for t in s.transitions:
			trs.append(t)
		s.transitions = trs

	# AirMove -> Land when Vertical lands; Land -> WalkCruiseMean.
	var land_row := FFTransition.new()
	var lc := FFCondition.new()
	lc.type = FFCondition.Type.ON_STATE
	lc.target_machine_name = &"Vertical"
	lc.target_state_name = &"Ground"
	land_row.condition = lc
	land_row.target_state_name = &"Land"
	air.transitions = [land_row, _complete_row(air)]

	# Post-landing cruise: mean speed (phase of the quasi-periodic sawtooth
	# is unknowable after the jump; mean keeps error bounded).
	var cruise_mean := _state("WalkCruiseMean", 1, 31.688 * SIM_TO_M, Vector3.ZERO)
	cruise_mean.direction_source = FrameState.DirectionSource.INPUT
	_set_input_actions(cruise_mean)
	land.transitions = [_complete_row_by_name("WalkCruiseMean")]
	cruise_mean.transitions = [_complete_row_by_name("WalkCruiseMean")]

	loco.states.append(air)
	loco.states.append(land)
	loco.states.append(cruise_mean)


func _complete_row_by_name(sname: String) -> FFTransition:
	var row := FFTransition.new()
	var c := FFCondition.new()
	c.type = FFCondition.Type.ON_COMPLETE
	row.condition = c
	row.target_state_name = StringName(sname)
	return row


## Per-frame walk displacements from the full decomp formula, 200 frames.
## (Covers the accel ramp and the cruise sawtooth limit cycle.)
func _walk_profile() -> Array:
	var out := []
	var v := 8.0
	for i in 400:
		if v <= 0.0:
			v += 1.1
		elif v <= 32.0:
			v += 1.1 - v / 43.0
		else:
			v -= 1.0
		v = minf(v, 48.0)
		out.append(v)
	return out


# ------------------------------------------------------------------ helpers ---

func _state(sname: String, dur: int, disp: float, dir: Vector3) -> FrameState:
	var s := FrameState.new()
	s.state_name = sname
	s.duration_frames = dur
	s.displacement = disp
	s.direction = dir
	return s


func _set_input_actions(s: FrameState) -> void:
	s.input_left = "ff_left"
	s.input_right = "ff_right"
	s.input_forward = "ff_fwd"
	s.input_back = "ff_back"
	s.input_plane = FrameState.InputPlane.XZ
	# SM64 facing turn rate (decomp approach_s32 0x800/frame).
	s.input_turn_rate_deg = 11.25


func _complete_row(target: FrameState) -> FFTransition:
	var row := FFTransition.new()
	var c := FFCondition.new()
	c.type = FFCondition.Type.ON_COMPLETE
	row.condition = c
	row.target_state_name = target.state_name
	return row


func _input_row(actions: Array, mode: int, target: FrameState) -> FFTransition:
	var row := FFTransition.new()
	var c := FFCondition.new()
	c.type = FFCondition.Type.ON_INPUT
	var pa := PackedStringArray()
	for a in actions:
		pa.append(a)
	c.input_actions = pa
	c.input_mode = mode
	row.condition = c
	row.target_state_name = target.state_name
	return row


## Curve with weights proportional to the given per-frame values.
## Uses LINEAR tangents to avoid cubic overshoot on abrupt changes.
func _fit_curve(values: Array) -> Curve:
	var c := Curve.new()
	var n: int = values.size()
	var mx := 0.0
	for v in values:
		mx = maxf(mx, float(v))
	for k in n:
		c.add_point(Vector2(float(k) / float(n), float(values[k]) / mx), 0.0, 0.0, Curve.TANGENT_LINEAR, Curve.TANGENT_LINEAR)
	c.add_point(Vector2(1.0, float(values[n - 1]) / mx), 0.0, 0.0, Curve.TANGENT_LINEAR, Curve.TANGENT_LINEAR)
	return c


## Exact per-frame curve (LINEAR tangents, no cubic overshoot).
## Use for profiles with abrupt changes.
func _fit_curve_exact(values: Array) -> Curve:
	var c := Curve.new()
	var n: int = values.size()
	var mx := 0.0
	for v in values:
		mx = maxf(mx, float(v))
	for k in n:
		c.add_point(Vector2(float(k) / float(n), float(values[k]) / mx), 0.0, 0.0, Curve.TANGENT_LINEAR, Curve.TANGENT_LINEAR)
	c.add_point(Vector2(1.0, float(values[n - 1]) / mx), 0.0, 0.0, Curve.TANGENT_LINEAR, Curve.TANGENT_LINEAR)
	return c


## Brake curve: -4/frame decel from 32, shifted so frame 0 already braked.
func _brake_curve() -> Curve:
	var c := Curve.new()
	var n := 8
	for k in n:
		var w := float(8 - (k + 1)) / 8.0
		c.add_point(Vector2(float(k) / float(n), maxf(w, 0.0)))
	c.add_point(Vector2(1.0, 0.0))
	return c


## Linear 1 -> 0 decay over n frames (for ENTRY braking).
func _linear_decay_curve(n: int) -> Curve:
	var c := Curve.new()
	for k in n:
		c.add_point(Vector2(float(k) / float(n), 1.0 - float(k) / float(n)))
	c.add_point(Vector2(1.0, 0.0))
	return c


func _save(bh: FrameBehavior, fname: String) -> void:
	var err := ResourceSaver.save(bh, OUT_DIR + fname)
	print("saved %s (%s)" % [fname, err])


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
