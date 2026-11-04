extends Node3D
## Tests for playground_animator.gd (unit) and the playground scene (integration).
## Run headless: godot --headless --path . res://tests/playground_anim_test.tscn
## Exit code 0 = all pass. The integration half needs the built GDExtension
## (BehaviorPlayer); without it, it is skipped gracefully.
##
## What "works as intended" means here:
## - every behavior state has an animation mapping (no silent fallbacks)
## - the body never clips through the ground (feet-pivot squash + bob lift)
## - no animation outlives its state: spins decay, the cap always comes home,
##   the squash spring settles instead of oscillating forever

var _failures: Array = []
var _frame := 0
var _pg: Node = null
var _min_y := 999999.0
var _states_seen := {}
var _unit := 1.0
var _integration := false
## Generation guard: queue_free() is deferred, so the previous playground's
## player can still emit state_entered for a frame after the switch. The
## lambda only records for the current generation.
var _gen := 0


func _check(cond: bool, name: String) -> void:
	if cond:
		print("PASS: ", name)
	else:
		_failures.append(name)
		print("FAIL: ", name)


func _ready() -> void:
	_unit_tests()
	if ClassDB.class_exists("BehaviorPlayer"):
		_integration = true
		_start_integration("smo")
	else:
		print("SKIP: integration (BehaviorPlayer missing; run tools/build_extension.ps1)")
		_finish()


func _all_states() -> Array:
	var out := []
	for path in ["res://rust/behaviors/smo_movement.json", "res://rust/behaviors/move.json",
			"res://rust/behaviors/smg_movement.json"]:
		var bh = JSON.parse_string(FileAccess.get_file_as_string(path))
		for sm in bh["sub_machines"]:
			for s in sm["states"]:
				out.append(str(s["state_name"]))
	return out


func _unit_tests() -> void:
	print("== animator unit tests ==")
	var a := PlaygroundAnimator.new()
	a.setup(1.0, Color.RED)
	add_child(a)  # at y=0: feet on the "floor"
	# 1. every state maps to a pose
	var states := _all_states()
	var bad := []
	for sn in states:
		a.set_state(sn)
		if not a.last_mapped:
			bad.append(sn)
	_check(bad.is_empty(), "coverage: %d states mapped (%s)" % [states.size(), "none missed" if bad.is_empty() else str(bad)])
	# 2. guards: safe before setup
	var a2 := PlaygroundAnimator.new()
	a2.set_state("run")
	a2.advance(0.016)
	_check(a2.body_min_y() == 0.0, "guards: set_state/advance/body_min_y safe before setup")
	# 3. squash spring settles on a slam pose (no endless oscillation)
	a.set_state("gp_land")
	for i in 180:
		a.advance(1.0 / 60.0)
	_check(a._squash.distance_to(Vector3(1.45, 0.48, 1.45)) < 0.05,
		"squash: slam pose settles (got %s)" % str(a._squash))
	# 4. yaw spin decays quickly after its state ends
	a.set_state("jump_spin")
	for i in 90:
		a.advance(1.0 / 60.0)
	a.set_state("tuck")
	for i in 45:
		a.advance(1.0 / 60.0)
	_check(absf(wrapf(a._actor.rotation.y, -PI, PI)) < 0.2,
		"anim lifetime: yaw spin settles after state ends")
	# 5. pitch spin decays (roll -> idle)
	a.set_state("roll")
	for i in 60:
		a.advance(1.0 / 60.0)
	a.set_state("idle")
	for i in 90:
		a.advance(1.0 / 60.0)
	_check(absf(wrapf(a._actor.rotation.x, -PI, PI)) < 0.1,
		"anim lifetime: pitch spin settles after state ends")
	# 6. cap throw/recall always completes (never stuck out)
	a.set_state("cap_throw")
	for i in 30:
		a.advance(1.0 / 60.0)
	_check(a._cap_mode == "out" and not a._head_cap.visible and a._fly_cap.visible,
		"cap: throw hides head cap, prop flies")
	a.set_state("dead")
	for i in 60:
		a.advance(1.0 / 60.0)
	_check(a._cap_mode == "head" and a._head_cap.visible and not a._fly_cap.visible,
		"anim lifetime: cap comes home after its state ends")
	# 7. no ground clip across every pose (feet pivot + bob lift)
	var worst := 0.0
	for sn in states:
		a.set_state(sn)
		for i in 30:
			a.advance(1.0 / 60.0)
		worst = minf(worst, a.body_min_y())
	_check(worst >= -0.001, "clip: body never below feet across all poses (worst %.4f)" % worst)
	# 8. model faces velocity
	var pb := CharacterBody3D.new()
	add_child(pb)
	var a3 := PlaygroundAnimator.new()
	a3.setup(1.0, Color.RED)
	pb.add_child(a3)
	pb.velocity = Vector3(3, 0, -2)
	for i in 60:
		a3.advance(1.0 / 60.0)
	var want := atan2(-3.0, 2.0)
	_check(absf(wrapf(a3.rotation.y - want, -PI, PI)) < 0.15,
		"facing: model turns toward velocity")


func _start_integration(moveset: String) -> void:
	get_tree().set_meta("ff_moveset", moveset)
	var sc: PackedScene = load("res://playground.tscn")
	_pg = sc.instantiate()
	add_child(_pg)
	_frame = 0
	_min_y = 999999.0
	_states_seen = {}
	_unit = _pg._unit
	_gen += 1
	var g := _gen
	_pg._player.state_entered.connect(func(_b, _m, s): if g == _gen: _states_seen[s] = true)


func _drive_input() -> Dictionary:
	var inp := {"mx": 0.0, "my": 0.0, "jump": false, "crouch": false,
		"cap": false, "cam": 0.0, "menu": false}
	var ph: int = _frame / 40
	var t: int = _frame % 40
	if ph == 0:
		inp["my"] = 1.0
	elif ph == 1:
		inp["my"] = 1.0
		inp["jump"] = t < 3
	elif ph == 2:
		inp["jump"] = t < 3
		inp["cap"] = t == 12
	elif ph == 3:
		inp["crouch"] = true
		inp["my"] = 1.0
	elif ph == 4:
		inp["crouch"] = true
		inp["cap"] = t < 3
	elif ph == 5:
		inp["cap"] = t < 3
	elif ph == 6:
		inp["my"] = -1.0
	elif ph == 7:
		inp["mx"] = 1.0
		inp["cam"] = 0.5
	return inp


func _physics_process(_delta: float) -> void:
	if not _integration:
		return
	_frame += 1
	_pg.test_input = _drive_input()
	_min_y = minf(_min_y, _pg._animator.body_min_y())
	if _frame >= 360:
		var n := _states_seen.size()
		# SMG's machine is intentionally tiny (Walk/Jump/Hang; chaining,
		# wall slide, spin and pound are internal to Jump).
		var min_states := {"smo": 6, "sm64": 6, "smg": 2}
		_check(_min_y >= -0.05 * _unit,
			"integration[%s]: no ground clip over %d states (min y %.3f)" % [_pg._moveset, n, _min_y])
		_check(n >= int(min_states.get(_pg._moveset, 6)),
			"integration[%s]: exercised >=%d states (saw %d: %s)" % [_pg._moveset, int(min_states.get(_pg._moveset, 6)), n, str(_states_seen.keys()).left(120)])
		_check(_pg._animator.unmapped_states.is_empty(),
			"integration[%s]: no unmapped states" % _pg._moveset)
		var done_moveset: String = _pg._moveset
		_pg.queue_free()
		if done_moveset == "smo":
			_start_integration("sm64")
		elif done_moveset == "sm64":
			_start_integration("smg")
		else:
			_finish()


func _finish() -> void:
	print("playground_anim_test: %d failure(s)" % _failures.size())
	get_tree().quit(1 if not _failures.is_empty() else 0)
