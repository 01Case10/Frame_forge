extends Node3D
## Headless playtest for the Galaxy playground moveset (smg_movement.json).
## Run headless: godot --headless --path . res://tests/smg_playground_test.tscn
## Exit code 0 = all pass. Needs the built GDExtension (BehaviorPlayer).
##
## Script:
##  1. Walk north (my=1.0). Steering must turn Mario from +Z toward the
##     stick's world direction (-Z): z decreases. (Without the G-7 turn he
##     would walk +Z and z would increase.)
##  2. Jump: rises ~2.8 m.
##  3. Teleport beside the (0,4.2,-12) floater (top y=4.45) at grab height,
##     walk into its face while falling -> ledge grab (Hang).
##  4. Hold jump -> climb-out (after the 18-tick gate) -> Walk, up on top.
##  5. Spin (X) and ground pound (B) smoke checks (no crash, jump arcs).

var _failures: Array = []
var _frame := 0
var _pg: Node = null
var _phase := 0
var _saw := {}
var _jump_peak := 0.0
var _y40 := 0.0
var _y60 := 0.0


func _check(cond: bool, name: String) -> void:
	if cond:
		print("PASS: ", name)
	else:
		_failures.append(name)
		print("FAIL: ", name)


func _ready() -> void:
	if not ClassDB.class_exists("BehaviorPlayer"):
		print("SKIP: BehaviorPlayer missing; build the extension first")
		_finish()
		return
	get_tree().set_meta("ff_moveset", "smg")
	var sc: PackedScene = load("res://playground.tscn")
	_pg = sc.instantiate()
	add_child(_pg)
	_pg._player.state_entered.connect(func(_b, _m, s): _saw[s] = true)


func _drive() -> Dictionary:
	var inp := {"mx": 0.0, "my": 0.0, "jump": false, "crouch": false,
		"cap": false, "cam": 0.0, "menu": false}
	match _phase:
		0, 1, 2:
			inp["my"] = 1.0
			inp["jump"] = _phase == 1 and _frame < 3
		3:
			inp["jump"] = true
		4, 5:
			# Release first (phase 3 held jump), then press: the Walk->Jump
			# edge needs a fresh press.
			inp["jump"] = _frame >= 10 and _frame < 13
			inp["cap"] = _phase == 4 and _frame == 28
			inp["crouch"] = _phase == 5 and _frame == 40
	return inp


func _physics_process(_delta: float) -> void:
	if _pg == null:
		return
	_frame += 1
	_pg.test_input = _drive()
	var p = _pg._player
	var st: String = _pg._cur_state

	match _phase:
		0:
			if _frame >= 50:
				_check(p.position.z < 11.0,
					"steer: walked north toward stick (z %.2f)" % p.position.z)
				_phase = 1
				_frame = 0
		1:
			_jump_peak = maxf(_jump_peak, p.position.y)
			if _frame >= 90:
				_check(_jump_peak > 1.5,
					"jump: rose to %.2f m (Galaxy jump ~2.8)" % _jump_peak)
				_check(_saw.has("Jump"), "states: Jump entered")
				# Grab setup: south face of the (0,4.2,-12) floater
				# (top y=4.45); hands at 3.0+1.4=4.4, inside the window.
				p.position = Vector3(0, 3.0, -9.9)
				_saw.clear()
				_phase = 2
				_frame = 0
		2:
			if _frame >= 120:
				_check(_saw.has("Hang"),
					"ledge: Hang grabbed (saw %s)" % str(_saw.keys()))
				_phase = 3
				_frame = 0
		3:
			if _frame >= 80:
				_check(st == "Walk", "climb: back to Walk (in %s)" % st)
				_check(p.position.y > 3.8,
					"climb: mounted the ledge (y %.2f)" % p.position.y)
				p.position = Vector3(0, 0.1, 12)
				_phase = 4
				_frame = 0
				_jump_peak = 0.0
		4:
			_jump_peak = maxf(_jump_peak, p.position.y)
			if _frame == 28:
				_y40 = p.position.y
			if _frame == 48:
				_y60 = p.position.y
			if _frame >= 100:
				_check(_jump_peak > 0.5, "spin: jump rose (%.2f)" % _jump_peak)
				# Spin (ff_attack) while falling sets vy=12 u/tick: against
				# Galaxy's 1.8 u/tick^2 gravity it does not climb far, but it
				# arrests the fall. Without the spin Mario lands ~frame 46;
				# with it he is still well airborne at frame 48.
				_check(_y60 > 0.4,
					"spin: spin arrested the fall (y %.2f at f48)" % _y60)
				_phase = 5
				_frame = 0
				_jump_peak = 0.0
		5:
			_jump_peak = maxf(_jump_peak, p.position.y)
			if _frame >= 100:
				_check(_jump_peak > 0.5, "pound: jump rose (%.2f)" % _jump_peak)
				# Ground pound slams down at up to 150 u/tick: back on the
				# ground well before the phase ends.
				_check(p.position.y < 0.5,
					"pound: slammed back down (y %.2f)" % p.position.y)
				_finish()


func _finish() -> void:
	print("smg_playground_test: %d failure(s)" % _failures.size())
	get_tree().quit(1 if not _failures.is_empty() else 0)
