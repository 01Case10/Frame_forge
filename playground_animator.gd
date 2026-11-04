class_name PlaygroundAnimator
extends Node3D
## Procedural placeholder character + animation for the playground.
##
## A blob character (capsule body, eyes, wearable cap) built from primitives.
## Poses are data: STATE_POSE maps every behavior state (all 76 SMO states
## across both machines, plus the 9 SM64 states) to a pose key, and POSES
## holds the exaggerated squash-and-stretch targets. Transitions spring
## between poses (underdamped, so landings overshoot), with continuous
## procedural bob / spin / wobble / blink on top.
##
## The cap is special: cap_throw* states hide the head cap and fly a cap
## prop out on a canned arc; return states fly it back.

const STATE_POSE := {
	# SMO player (machine 0)
	"idle": "idle", "run": "run", "brake_stop": "brake", "brake_turn": "brake_turn",
	"pivot": "pivot", "pivot_moving": "pivot",
	"jump_select": "anticipate",
	"jump1": "jump", "jump1_cut": "tuck", "jump2": "jump", "jump2_cut": "tuck",
	"jump3": "jump_spin", "jump3_cut": "tuck",
	"land_sel": "land", "fall": "fall", "coyote": "fall",
	"crouch_idle": "crouch", "crouch_walk": "crouch_walk", "uncrouch": "uncrouch",
	"crouch_slide": "slide", "roll": "roll", "roll_standup": "uncrouch",
	"dive": "dive",
	"gp_stall": "pound_stall", "gp_fall": "pound_fall", "gp_land": "pound_land",
	"jump_gp": "pound_stall",
	"wall_slide": "wall_slide", "jump_wall": "wall_jump", "bonk": "bonk",
	"land_hard": "land_hard",
	"cap_throw": "throw", "cap_throw_air": "throw", "vault": "vault",
	"cap_bounce": "cap_bounce", "cap_bounce_dive": "cap_bounce", "cap_bounce_pound": "cap_bounce",
	"jump_cap_return": "cap_return_jump", "jump_cap_return_cut": "tuck",
	"cap_return_spin": "return_spin", "ground_spin": "ground_spin",
	"jump_long": "long_jump",
	"jump_back": "backflip",
	"jump_side": "sideflip",
	"jump_spin": "jump_spin", "jump_spin_drill": "jump_spin",
	"water_plunge": "plunge", "water_idle": "water_idle",
	"water_swim_surface": "swim", "water_swim_under": "swim",
	"water_jump": "jump", "water_run": "run",
	"bounce_entity": "bounce", "spindrill": "spindrill",
	"ledge_hang": "ledge_hang", "ledge_climb": "ledge_climb",
	"ceiling_hang": "ceiling_hang",
	"pole_cling": "pole", "pole_climb": "pole_climb",
	"pole_slide": "pole_slide", "pole_top": "pole_top",
	"knockback": "hurt", "knockback_land": "hurt_land", "dead": "dead",
	"held": "held", "pit_fall": "pit_fall", "pit_recover": "recover",
	"wall_push": "wall_push", "slope_slide": "slope_slide", "sand_sink": "sand_sink",
	# SMO cap (machine 1): body idles, the cap prop is driven separately.
	"cap_held": "idle", "cap_flying": "idle", "cap_hover": "idle",
	"cap_homing": "idle", "cap_returning": "idle",
	# SM64 (move.json)
	"Ground": "idle", "Idle": "idle",
	"WalkAccel": "run", "WalkCruise": "run", "WalkBrake": "brake",
	"JumpRise": "jump", "JumpRiseCut": "tuck",
	"JumpFallCut": "fall", "JumpFall": "fall",
	# SMG Galaxy (smg_movement.json)
	"Walk": "run", "Jump": "jump", "Hang": "ledge_hang",
}

# States that throw / recall the cap prop (exact names, not prefixes).
const CAP_OUT := ["cap_throw", "cap_throw_air", "cap_flying", "cap_hover"]
const CAP_BACK := ["cap_homing", "cap_returning", "jump_cap_return",
	"jump_cap_return_cut", "cap_return_spin", "dead"]

## Test hook: set_state sets this false when a state has no mapping.
var last_mapped := true
## Test hook: every state name that had no pose mapping.
var unmapped_states: Array = []

var _unit := 1.0
var _poses := {}
var _pose := {}
var _squash := Vector3.ONE
var _squash_v := Vector3.ZERO
var _pitch_angle := 0.0
var _spin_angle := 0.0
var _time := 0.0
var _blink_t := 0.0
var _next_blink := 2.0
var _cap_mode := "head"
var _cap_t := 0.0

var _squash_n: Node3D
var _actor: Node3D
var _body: MeshInstance3D
var _eye_l: MeshInstance3D
var _eye_r: MeshInstance3D
var _head_cap: Node3D
var _fly_cap: Node3D


static func _P(s: Vector3, lean := 0.0, tilt := 0.0, spin := 0.0, pitch := 0.0,
		bob := 0.0, bob_speed := 6.0, wobble := 0.0, slam := false,
		dive := 0.0) -> Dictionary:
	return {"s": s, "lean": lean, "tilt": tilt, "spin": spin, "pitch": pitch,
		"bob": bob, "bob_speed": bob_speed, "wobble": wobble, "slam": slam,
		"dive": dive}


static func _make_poses() -> Dictionary:
	return {
		"idle": _P(Vector3(1, 1, 1), 0, 0, 0, 0, 0.035, 2.2),
		"run": _P(Vector3(0.94, 1.07, 0.94), 0.28, 0, 0, 0, 0.06, 11.0),
		"brake": _P(Vector3(1.3, 0.62, 1.3), -0.32),
		"brake_turn": _P(Vector3(1.22, 0.72, 1.22), -0.25, 0.35),
		"pivot": _P(Vector3(1.12, 0.85, 1.12), 0, 0.4, 0, 0, 0, 6.0, 0.2),
		"anticipate": _P(Vector3(1.18, 0.78, 1.18), 0.1),
		"jump": _P(Vector3(0.8, 1.35, 0.8), 0.12),
		"jump_spin": _P(Vector3(0.8, 1.32, 0.8), 0, 0, 15.0),
		"tuck": _P(Vector3(1.12, 0.85, 1.12), 0.25),
		"fall": _P(Vector3(0.85, 1.28, 0.85), 0.08, 0, 0, 0, 0, 6.0, 0.12),
		"land": _P(Vector3(1.32, 0.6, 1.32), 0.15),
		"land_hard": _P(Vector3(1.4, 0.52, 1.4), 0, 0, 0, 0, 0, 6.0, 0, true),
		"crouch": _P(Vector3(1.18, 0.58, 1.18)),
		"crouch_walk": _P(Vector3(1.15, 0.62, 1.15), 0, 0, 0, 0, 0.04, 8.0),
		"uncrouch": _P(Vector3(0.9, 1.22, 0.9)),
		"slide": _P(Vector3(1.2, 0.6, 1.2), 0.5),
		"roll": _P(Vector3(1.05, 0.9, 1.05), 0, 0, 0, 11.0),
		"dive": _P(Vector3(0.9, 0.9, 1.3), 0, 0, 0, 0, 0, 6.0, 0, false, -1.2),
		"pound_stall": _P(Vector3(0.85, 1.32, 0.85), 0, 0, 0, 0, 0, 6.0, 0.1),
		"pound_fall": _P(Vector3(0.9, 1.28, 0.9)),
		"pound_land": _P(Vector3(1.45, 0.48, 1.45), 0, 0, 0, 0, 0, 6.0, 0, true),
		"wall_slide": _P(Vector3(0.95, 1.06, 0.95), 0, 0.5, 0, 0, 0, 6.0, 0.15),
		"wall_jump": _P(Vector3(0.8, 1.35, 0.8), 0, -0.35),
		"bonk": _P(Vector3(1.3, 0.7, 1.3), 0, 0.2, 0, 0, 0, 6.0, 0.35),
		"throw": _P(Vector3(0.95, 1.12, 0.95), 0.45),
		"vault": _P(Vector3(0.85, 1.3, 0.85), 0.55),
		"cap_bounce": _P(Vector3(1.28, 0.68, 1.28)),
		"cap_return_jump": _P(Vector3(0.85, 1.3, 0.85), 0, 0, 9.0),
		"return_spin": _P(Vector3(0.9, 1.15, 0.9), 0, 0, 16.0),
		"ground_spin": _P(Vector3(1.1, 0.85, 1.1), 0, 0, 18.0),
		"long_jump": _P(Vector3(0.9, 0.95, 1.28), 0.55),
		"backflip": _P(Vector3(0.85, 1.3, 0.85), 0, 0, 0, -9.0),
		"sideflip": _P(Vector3(0.85, 1.3, 0.85), 0, 0.6, 8.0),
		"plunge": _P(Vector3(0.85, 1.3, 0.85), 0.3),
		"water_idle": _P(Vector3(1, 1, 1), 0, 0, 0, 0, 0.05, 1.5),
		"swim": _P(Vector3(0.92, 0.92, 1.2), 0, 0, 0, 0, 0.04, 4.0, 0, false, -1.0),
		"bounce": _P(Vector3(1.3, 0.65, 1.3)),
		"spindrill": _P(Vector3(0.8, 1.4, 0.8), 0, 0, 26.0, 0, 0, 6.0, 0, false, -0.5),
		"ledge_hang": _P(Vector3(0.92, 1.12, 0.92), -0.35),
		"ledge_climb": _P(Vector3(0.9, 1.25, 0.9), -0.15, 0, 0, 0, 0.05, 6.0),
		"ceiling_hang": _P(Vector3(0.95, 1.05, 0.95), 0, 0, 0, 0, 0, 6.0, 0, false, PI),
		"pole": _P(Vector3(0.9, 1.15, 0.9)),
		"pole_climb": _P(Vector3(0.9, 1.15, 0.9), 0, 0, 0, 0, 0.06, 7.0),
		"pole_slide": _P(Vector3(0.95, 1.05, 0.95), 0, 0, 0, 0, 0, 6.0, 0.1),
		"pole_top": _P(Vector3(0.9, 1.25, 0.9), -0.1),
		"hurt": _P(Vector3(1.25, 0.7, 1.25), 0, 0.5, 0, 0, 0, 6.0, 0.3),
		"hurt_land": _P(Vector3(1.35, 0.58, 1.35), 0, 0, 0, 0, 0, 6.0, 0, true),
		"dead": _P(Vector3(1.42, 0.45, 1.42), 0, 0.35, 0, 0, 0, 6.0, 0, true),
		"held": _P(Vector3(1.05, 0.95, 1.05), 0, 0, 0, 0, 0, 6.0, 0.45),
		"pit_fall": _P(Vector3(0.8, 1.35, 0.8), 0, 0, 0, 0, 0, 6.0, 0.4),
		"recover": _P(Vector3(0.9, 1.2, 0.9)),
		"wall_push": _P(Vector3(1.05, 0.95, 1.05), 0.45, 0, 0, 0, 0.03, 9.0),
		"slope_slide": _P(Vector3(1.15, 0.8, 1.15), -0.4),
		"sand_sink": _P(Vector3(1.2, 0.7, 1.2), 0, 0, 0, 0, 0, 6.0, 0.1),
	}


func setup(unit: float, color: Color) -> void:
	_unit = unit
	_poses = _make_poses()
	_pose = _poses["idle"]
	_build(color)


func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.6
	return m


func _make_cap(color: Color) -> Node3D:
	var n := Node3D.new()
	var top := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.22 * _unit
	cyl.bottom_radius = 0.26 * _unit
	cyl.height = 0.22 * _unit
	top.mesh = cyl
	top.material_override = _mat(color)
	n.add_child(top)
	var brim := MeshInstance3D.new()
	var bc := CylinderMesh.new()
	bc.top_radius = 0.3 * _unit
	bc.bottom_radius = 0.3 * _unit
	bc.height = 0.05 * _unit
	brim.mesh = bc
	brim.material_override = _mat(color.darkened(0.15))
	brim.position = Vector3(0, -0.08 * _unit, -0.22 * _unit)
	n.add_child(brim)
	return n


func _build(color: Color) -> void:
	# Squash pivots at the feet (player origin): scaling never pushes the
	# body through the floor, and stretch grows upward.
	_squash_n = Node3D.new()
	add_child(_squash_n)
	_actor = Node3D.new()
	_actor.position = Vector3(0, 0.9 * _unit, 0)
	_squash_n.add_child(_actor)
	var body := MeshInstance3D.new()
	var capm := CapsuleMesh.new()
	capm.radius = BODY_R * _unit
	capm.height = BODY_H * _unit
	body.mesh = capm
	body.material_override = _mat(color)
	_actor.add_child(body)
	_body = body
	# Eyes on the front (-z, Godot forward).
	for sx in [-1.0, 1.0]:
		var eye := MeshInstance3D.new()
		var es := SphereMesh.new()
		es.radius = 0.13 * _unit
		es.height = 0.26 * _unit
		eye.mesh = es
		eye.material_override = _mat(Color(1, 1, 1))
		eye.position = Vector3(sx * 0.17 * _unit, 0.38 * _unit, -0.33 * _unit)
		_actor.add_child(eye)
		var pupil := MeshInstance3D.new()
		var ps := SphereMesh.new()
		ps.radius = 0.055 * _unit
		ps.height = 0.11 * _unit
		pupil.mesh = ps
		pupil.material_override = _mat(Color(0.08, 0.08, 0.1))
		pupil.position = Vector3(sx * 0.17 * _unit, 0.38 * _unit, -0.43 * _unit)
		_actor.add_child(pupil)
		if sx < 0.0:
			_eye_l = eye
		else:
			_eye_r = eye
	_head_cap = _make_cap(Color(0.85, 0.15, 0.15))
	_head_cap.position = Vector3(0, 0.82 * _unit, 0.02 * _unit)
	_actor.add_child(_head_cap)
	# Flying cap prop: child of the root so squash never bends it.
	_fly_cap = _make_cap(Color(0.85, 0.15, 0.15))
	_fly_cap.visible = false
	add_child(_fly_cap)


func set_state(state_name: String) -> void:
	if _poses.is_empty():
		return
	if state_name in CAP_OUT:
		_throw_cap()
	elif state_name in CAP_BACK:
		_recall_cap()
	elif state_name == "cap_held":
		_cap_mode = "head"
		_fly_cap.visible = false
		_head_cap.visible = true
	if STATE_POSE.has(state_name):
		_pose = _poses[STATE_POSE[state_name]]
		last_mapped = true
		if bool(_pose["slam"]):
			_squash_v = (_pose["s"] - _squash) * 10.0
	else:
		_pose = _poses["idle"]
		last_mapped = false
		unmapped_states.append(state_name)
		push_warning("PlaygroundAnimator: unmapped state '%s'" % state_name)


func _throw_cap() -> void:
	_head_cap.visible = false
	_fly_cap.visible = true
	_cap_mode = "out"
	_cap_t = 0.0


func _recall_cap() -> void:
	if _cap_mode == "head":
		return
	_cap_mode = "back"


func _advance_cap(delta: float) -> void:
	if _cap_mode == "head":
		return
	var yaw := rotation.y
	var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
	if _cap_mode == "out":
		_cap_t = minf(1.0, _cap_t + delta / 0.8)
	elif _cap_mode == "back":
		_cap_t = maxf(0.0, _cap_t - delta / 0.35)
	_fly_cap.position = Vector3(0, 1.7 * _unit, 0) + fwd * (_cap_t * 5.0 * _unit) \
		+ Vector3(0, sin(_cap_t * PI) * 1.6 * _unit, 0)
	_fly_cap.rotation.y += 22.0 * delta
	if _cap_mode == "back" and _cap_t <= 0.0:
		_cap_mode = "head"
		_fly_cap.visible = false
		_head_cap.visible = true


# Body capsule dimensions (unit space) shared by _build and body_min_y.
const BODY_R := 0.42
const BODY_H := 1.8
const BODY_SPINE := 0.9 - 0.42  # half of the cylinder mid-section


## Lowest point of the body capsule in global space. Exact (not the AABB,
## which is conservative under tilt). The squash pivots at the feet and
## downward bob is compensated, so this must never go below the surface
## the player stands on.
func body_min_y() -> float:
	if _body == null:
		return 0.0
	var gt: Transform3D = _body.global_transform
	var rot: Basis = gt.basis.orthonormalized()
	var p: Vector3 = rot * Vector3(0, -BODY_SPINE * _unit, 0) \
		- Vector3(0, BODY_R * _unit, 0)
	return (gt * p).y


func advance(delta: float) -> void:
	if _poses.is_empty():
		return
	_time += delta
	var pb := get_parent() as CharacterBody3D
	if pb != null:
		var v: Vector3 = pb.velocity
		if Vector2(v.x, v.z).length() > 0.3 * _unit:
			var target_yaw := atan2(-v.x, -v.z)
			rotation.y = lerp_angle(rotation.y, target_yaw, minf(1.0, 10.0 * delta))
	# Squash spring: underdamped so transitions overshoot (juice).
	var target: Vector3 = _pose["s"]
	_squash_v += ((target - _squash) * 170.0 - _squash_v * 13.0) * delta
	_squash += _squash_v * delta
	_squash_n.scale = _squash
	# Pitch: continuous spin (roll/backflip) or lean+dive pose.
	var px: float = _pose["pitch"]
	if px != 0.0:
		_pitch_angle += px * delta
		_actor.rotation.x = _pitch_angle
	else:
		_pitch_angle = _actor.rotation.x
		_actor.rotation.x = lerp_angle(_actor.rotation.x,
			float(_pose["lean"]) + float(_pose["dive"]), minf(1.0, 12.0 * delta))
	# Yaw spin (triple jump, spins); ease back to neutral when done.
	var sp: float = _pose["spin"]
	if sp != 0.0:
		_spin_angle += sp * delta
		_actor.rotation.y = _spin_angle
	else:
		_spin_angle = _actor.rotation.y
		_actor.rotation.y = lerp_angle(_actor.rotation.y,
			round(_spin_angle / TAU) * TAU, minf(1.0, 10.0 * delta))
	# Tilt + wobble.
	var wob: float = _pose["wobble"]
	_actor.rotation.z = lerpf(_actor.rotation.z, float(_pose["tilt"]),
		minf(1.0, 12.0 * delta)) + sin(_time * 13.0) * wob
	# Bob. Downward bob is lifted back out so the feet never dip below
	# the squash pivot (rotation alone can't clip: the capsule's vertical
	# half-extent only shrinks when rotated).
	var bob_y := sin(_time * float(_pose["bob_speed"])) * float(_pose["bob"])
	_actor.position.y = 0.9 * _unit - minf(0.0, bob_y)
	# Blink.
	_next_blink -= delta
	if _next_blink <= 0.0:
		_blink_t = 0.12
		_next_blink = randf_range(1.8, 4.2)
	if _blink_t > 0.0:
		_blink_t -= delta
		_eye_l.scale = Vector3(1, 0.15, 1)
		_eye_r.scale = Vector3(1, 0.15, 1)
	else:
		_eye_l.scale = Vector3.ONE
		_eye_r.scale = Vector3.ONE
	_advance_cap(delta)
