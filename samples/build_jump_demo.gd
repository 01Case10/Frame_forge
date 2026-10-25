extends SceneTree
## Builds samples/jump_demo.tres: a hand-authored Ground/Air behavior pair
## demonstrating parallel machines, ENTRY braking, input conditions,
## behavior switching, and contact-event landing.
## Run: godot --headless --path . --script res://samples/build_jump_demo.gd

const MOVE_ACTIONS := ["ui_left", "ui_right", "ui_forward", "ui_back"]


const GROUND_PATH := "res://samples/jump_demo_ground.tres"
const AIR_PATH := "res://samples/jump_demo_air.tres"


func _init() -> void:
	var ground := _build_ground()
	var air := _build_air()
	# Cross-behavior refs must be ext_resource links, not embedded cycles:
	# save each file once without the back-ref, then wire and re-save.
	var err := ResourceSaver.save(air, AIR_PATH)
	print("saved air (pass 1): ", err)
	# Ground --jump--> Air.
	for s in [ground.sub_machines[0].states[0], ground.sub_machines[0].states[1]]:
		var row := _input_row(["ui_accept"], FFCondition.InputMode.ANY_PRESSED)
		row.target_behavior = air
		s.transitions.append(row)
	err = ResourceSaver.save(ground, GROUND_PATH)
	print("saved ground: ", err)
	# Air --floor_gained--> Ground.
	var land := FFTransition.new()
	var lc := FFCondition.new()
	lc.type = FFCondition.Type.ON_EVENT
	lc.event_name = "floor_gained"
	land.condition = lc
	land.target_behavior = load(GROUND_PATH)
	air.behavior_transitions = [land]
	err = ResourceSaver.save(air, AIR_PATH)
	print("saved air (pass 2): ", err)

	var issues: Array = FFValidator.validate_behavior(ground)
	issues.append_array(FFValidator.validate_behavior(air))
	var errs := issues.filter(func(i: Dictionary) -> bool: return i["severity"] == "error")
	print("validation: %d issues, %d errors" % [issues.size(), errs.size()])
	for i in issues:
		print("  [%s] %s" % [i["severity"], i["message"]])
	quit(0 if errs.is_empty() else 1)


func _ease_out() -> Curve:
	var c := Curve.new()
	c.add_point(Vector2(0, 0))
	c.add_point(Vector2(1, 1))
	c.set_point_right_tangent(0, 1.6)
	c.set_point_left_tangent(1, 0.0)
	return c


func _state(sname: String, dur: int, disp: float, dir: Vector3, pos: Vector2) -> FrameState:
	var s := FrameState.new()
	s.state_name = sname
	s.duration_frames = dur
	s.displacement = disp
	s.direction = dir
	s.editor_position = pos
	return s


func _complete_row(target: FrameState) -> FFTransition:
	var row := FFTransition.new()
	var c := FFCondition.new()
	c.type = FFCondition.Type.ON_COMPLETE
	row.condition = c
	row.target_state_name = target.state_name
	return row


func _input_row(actions: Array, mode: int) -> FFTransition:
	var row := FFTransition.new()
	var c := FFCondition.new()
	c.type = FFCondition.Type.ON_INPUT
	var pa := PackedStringArray()
	for a in actions:
		pa.append(a)
	c.input_actions = pa
	c.input_mode = mode
	row.condition = c
	return row


func _build_ground() -> FrameBehavior:
	var bh := FrameBehavior.new()
	bh.behavior_name = "Ground"

	# Locomotion machine.
	var idle := _state("Idle", 1, 0.0, Vector3.ZERO, Vector2(0, 0))
	var run := _state("Run", 1, 0.14, Vector3.ZERO, Vector2(300, 0))
	run.direction_source = FrameState.DirectionSource.INPUT
	run.input_left = "ui_left"
	run.input_right = "ui_right"
	run.input_forward = "ui_forward"
	run.input_back = "ui_back"
	var brake := _state("Brake", 6, 0.0, Vector3.ZERO, Vector2(600, 0))
	brake.direction_source = FrameState.DirectionSource.ENTRY
	brake.displacement_source = FrameState.DisplacementSource.ENTRY
	brake.easing = _ease_out()
	idle.transitions = [_input_row(MOVE_ACTIONS, FFCondition.InputMode.ANY_PRESSED)]
	idle.transitions[0].target_state_name = run.state_name
	idle.transitions.append(_complete_row(idle))
	run.transitions = []
	var brake_row := _input_row(MOVE_ACTIONS, FFCondition.InputMode.ALL_RELEASED)
	brake_row.target_state_name = brake.state_name
	run.transitions.append(brake_row)
	run.transitions.append(_complete_row(run))
	brake.transitions = [_complete_row(idle)]
	var loco := SubStateMachine.new()
	loco.machine_name = "Locomotion"
	loco.states = [idle, run, brake]
	loco.entry_state = idle

	# Vertical machine (grounded hold; exits via behavior switch to Air).
	var grounded := _state("Grounded", 1, 0.0, Vector3.ZERO, Vector2(0, 240))
	grounded.transitions = [_complete_row(grounded)]
	var vert := SubStateMachine.new()
	vert.machine_name = "Vertical"
	vert.states = [grounded]
	vert.entry_state = grounded

	bh.sub_machines = [loco, vert]
	return bh


func _build_air() -> FrameBehavior:
	var bh := FrameBehavior.new()
	bh.behavior_name = "Air"

	var rise := _state("Rise", 14, 4.48, Vector3.UP, Vector2(0, 0))
	rise.easing = _ease_out()
	var fall := _state("Fall", 1, 0.42, Vector3.DOWN, Vector2(300, 0))
	rise.transitions = [_complete_row(fall)]
	fall.transitions = [_complete_row(fall)]
	# Landing is handled by the Air behavior's floor_gained behavior transition.
	var vert := SubStateMachine.new()
	vert.machine_name = "Vertical"
	vert.states = [rise, fall]
	vert.entry_state = rise

	var airmove := _state("AirMove", 1, 0.1, Vector3.ZERO, Vector2(0, 240))
	airmove.direction_source = FrameState.DirectionSource.INPUT
	airmove.input_left = "ui_left"
	airmove.input_right = "ui_right"
	airmove.input_forward = "ui_forward"
	airmove.input_back = "ui_back"
	airmove.transitions = [_complete_row(airmove)]
	var horiz := SubStateMachine.new()
	horiz.machine_name = "Horizontal"
	horiz.states = [airmove]
	horiz.entry_state = airmove

	bh.sub_machines = [vert, horiz]
	return bh
