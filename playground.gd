extends Node3D
## Free-play playground: a small platforming level (floor, walls, stairs,
## floating platforms, pillars) with a BehaviorPlayer you drive by gamepad.
## Moveset comes from the menu via the SceneTree meta "ff_moveset":
## "sm64" (Mario 64, res://rust/behaviors/move.json) or "smo" (Odyssey,
## res://rust/behaviors/smo_movement.json).
##
## Controls: left stick move (camera-relative), right stick orbits camera,
## A/jump, B/crouch, X/cap (Odyssey). Keyboard: WASD/arrows + Space, C, E.
## Esc or Start returns to the menu.
##
## Unit note: the two movesets are authored in different native units
## (sm64 = meters, smo = SMO decomp centimeters, verified empirically:
## smo run cap 14 u/tick = 8.4 m/s, jump peak ~328 u = 3.3 m). The level,
## player capsule and camera are all built in the moveset's native units
## (UNIT), so each moveset plays at its authored scale.

const MOVESETS := {
	"sm64": {
		"label": "Mario 64",
		"behavior": "res://rust/behaviors/move.json",
		"color": Color(0.9, 0.3, 0.25),
		"unit": 1.0,
		"hint": "A: jump",
	},
	"smo": {
		"label": "Odyssey",
		"behavior": "res://rust/behaviors/smo_movement.json",
		"color": Color(0.3, 0.5, 0.95),
		"unit": 100.0,
		"hint": "A: jump   B: crouch   X: cap throw",
	},
}

const DEADZONE := 0.18
const CAM_SENS := 2.4
const SPAWN := Vector3(0, 0.1, 12)

# [center, size, color] in unit space; walls keep you in, stairs and
# floaters are 1u hops (both movesets clear them), deck/skydeck reward climbing.
const BOXES := [
	[Vector3(0, -1, 0), Vector3(48, 2, 48), Color(0.24, 0.3, 0.26)],
	[Vector3(0, 2.5, -23.5), Vector3(48, 7, 1), Color(0.45, 0.45, 0.5)],
	[Vector3(0, 2.5, 23.5), Vector3(48, 7, 1), Color(0.45, 0.45, 0.5)],
	[Vector3(-23.5, 2.5, 0), Vector3(1, 7, 48), Color(0.45, 0.45, 0.5)],
	[Vector3(23.5, 2.5, 0), Vector3(1, 7, 48), Color(0.45, 0.45, 0.5)],
	[Vector3(-14, 0.5, -4), Vector3(4, 1, 4), Color(0.75, 0.55, 0.3)],
	[Vector3(-14, 1.5, -8), Vector3(4, 1, 4), Color(0.75, 0.55, 0.3)],
	[Vector3(-14, 2.5, -12), Vector3(4, 1, 4), Color(0.75, 0.55, 0.3)],
	[Vector3(-14, 3.5, -16), Vector3(4, 1, 4), Color(0.75, 0.55, 0.3)],
	[Vector3(-14, 4.5, -20), Vector3(6, 1, 4), Color(0.7, 0.4, 0.35)],
	[Vector3(-6, 3.2, -10), Vector3(3.2, 0.5, 3.2), Color(0.85, 0.65, 0.3)],
	[Vector3(0, 4.2, -12), Vector3(3.2, 0.5, 3.2), Color(0.85, 0.65, 0.3)],
	[Vector3(6, 5.2, -10), Vector3(3.2, 0.5, 3.2), Color(0.85, 0.65, 0.3)],
	[Vector3(6, 6.2, -16), Vector3(6, 1, 5), Color(0.7, 0.4, 0.35)],
	[Vector3(12, 0.5, 8), Vector3(3, 1, 3), Color(0.5, 0.5, 0.55)],
	[Vector3(16, 0.5, 2), Vector3(2.5, 1, 2.5), Color(0.5, 0.5, 0.55)],
]

## Test hook: when non-empty, _physics_process uses this instead of devices.
## Keys: mx, my, jump, crouch, cap, cam, menu.
var test_input := {}

var _player: BehaviorPlayer
var _rig: Node3D
var _state_label: Label
var _moveset := "sm64"
var _unit := 1.0
var _ms_label := "Mario 64"
var _phi := 0.0
var _pad := -1
var _animator: PlaygroundAnimator
# Supplemental gravity for movesets without authored falling (sm64):
# applied only while airborne and the behavior commanded ~no vertical.
var _grav_v := 0.0


func _ready() -> void:
	for a in ["jump", "crouch", "cap", "cap_throw_up", "cap_throw_down", "ff_jump", "ff_left", "ff_right", "ff_fwd", "ff_back"]:
		if not InputMap.has_action(a):
			InputMap.add_action(a)
	var tree := get_tree()
	_moveset = str(tree.get_meta("ff_moveset", "sm64"))
	if not MOVESETS.has(_moveset):
		_moveset = "sm64"
	var ms: Dictionary = MOVESETS[_moveset]
	_unit = float(ms["unit"])
	_ms_label = str(ms["label"])
	_build_level()
	_build_player(ms)
	_build_camera()
	_build_hud(ms)


func _build_level() -> void:
	for b in BOXES:
		_add_box(b[0], b[1], b[2])


func _add_box(center: Vector3, size: Vector3, color: Color) -> void:
	var body := StaticBody3D.new()
	body.position = center * _unit
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size * _unit
	cs.shape = shape
	body.add_child(cs)
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size * _unit
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mi.material_override = mat
	body.add_child(mi)
	add_child(body)


func _build_player(ms: Dictionary) -> void:
	_player = BehaviorPlayer.new()
	_player.auto_step = false
	var ok := _player.load_behavior(str(ms["behavior"]))
	if not ok:
		push_error("playground: failed to load " + str(ms["behavior"]))
	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4 * _unit
	cap.height = 1.8 * _unit
	col.shape = cap
	col.position = Vector3(0, 0.9 * _unit, 0)
	_player.add_child(col)
	_player.floor_snap_length = 0.4 * _unit
	_player.position = SPAWN * _unit
	add_child(_player)
	_animator = PlaygroundAnimator.new()
	_animator.setup(_unit, ms["color"])
	_player.add_child(_animator)
	_player.state_entered.connect(_on_state)


func _build_camera() -> void:
	_rig = Node3D.new()
	_rig.name = "CameraRig"
	_rig.position = _player.position + Vector3(0, 1.4 * _unit, 0)
	add_child(_rig)
	var arm := SpringArm3D.new()
	arm.spring_length = 7.0 * _unit
	arm.rotation.x = -0.32
	_rig.add_child(arm)
	var cam := Camera3D.new()
	cam.current = true
	cam.far = 200.0 * _unit
	arm.add_child(cam)
	var light: DirectionalLight3D = $DirectionalLight3D
	light.directional_shadow_max_distance = 60.0 * _unit


func _build_hud(ms: Dictionary) -> void:
	var hud := CanvasLayer.new()
	add_child(hud)
	_state_label = Label.new()
	_state_label.position = Vector2(20, 20)
	_state_label.add_theme_font_size_override("font_size", 28)
	_state_label.text = "%s - free play" % _ms_label
	hud.add_child(_state_label)
	var controls := Label.new()
	controls.position = Vector2(20, 60)
	controls.add_theme_font_size_override("font_size", 18)
	var pad := "gamepad" if not Input.get_connected_joypads().is_empty() else "no gamepad (keyboard works)"
	controls.text = "Left stick: move    Right stick: camera    %s    Start/Esc: menu    [%s]" % [str(ms["hint"]), pad]
	hud.add_child(controls)


# Debug: log state transitions to console. Toggle with F3.
var debug_log_states := false
var _prev_state := ""
var _f3_held := false

func _on_state(_behavior: String, _machine: String, state: String) -> void:
	_state_label.text = "%s - %s" % [_ms_label, state]
	_animator.set_state(state)
	if debug_log_states and state != _prev_state:
		var gd: float = _player.get_param("ground.dist")
		var hs: float = _player.get_param("motion.hspeed")
		var wall: bool = _player.get_param("contact.wall")
		# Stick input (what the player is actually pressing)
		var sx: float = Input.get_action_strength("ui_right") - Input.get_action_strength("ui_left")
		var sy: float = Input.get_action_strength("ui_up") - Input.get_action_strength("ui_down")
		print("[STATE] %s -> %s | pos=%s hspeed=%.1f ground.dist=%.1f wall=%s stick=(%.2f, %.2f)" % [
			_prev_state, state, str(_player.position).replace("\n", ""), hs, gd, str(wall), sx, sy])
	_prev_state = state


func _key(pos: Key, neg: Key) -> float:
	var v := 0.0
	if Input.is_physical_key_pressed(pos):
		v += 1.0
	if Input.is_physical_key_pressed(neg):
		v -= 1.0
	return v


func _read_devices() -> Dictionary:
	var pads := Input.get_connected_joypads()
	_pad = int(pads[0]) if not pads.is_empty() else -1
	var jx := 0.0
	var jy := 0.0
	var rcx := 0.0
	var jump := false
	var crouch := false
	var capb := false
	var start := false
	if _pad >= 0:
		jx = Input.get_joy_axis(_pad, JOY_AXIS_LEFT_X)
		jy = Input.get_joy_axis(_pad, JOY_AXIS_LEFT_Y)
		rcx = Input.get_joy_axis(_pad, JOY_AXIS_RIGHT_X)
		jump = Input.is_joy_button_pressed(_pad, JOY_BUTTON_A)
		crouch = Input.is_joy_button_pressed(_pad, JOY_BUTTON_B)
		capb = Input.is_joy_button_pressed(_pad, JOY_BUTTON_X)
		start = Input.is_joy_button_pressed(_pad, JOY_BUTTON_START)
	var kx := _key(KEY_D, KEY_A) + _key(KEY_RIGHT, KEY_LEFT)
	var ky := _key(KEY_W, KEY_S) + _key(KEY_UP, KEY_DOWN)
	return {
		"mx": clampf(jx + kx, -1.0, 1.0),
		"my": clampf(-jy + ky, -1.0, 1.0),
		"jump": jump or Input.is_physical_key_pressed(KEY_SPACE),
		"crouch": crouch or Input.is_physical_key_pressed(KEY_C),
		"cap": capb or Input.is_physical_key_pressed(KEY_E),
		"cam": rcx,
		"menu": start,
	}


func _set_action(action: StringName, strength: float) -> void:
	if strength > DEADZONE:
		Input.action_press(action, minf(strength, 1.0))
	else:
		Input.action_release(action)


func _set_btn(action: StringName, held: bool) -> void:
	if held:
		Input.action_press(action, 1.0)
	else:
		Input.action_release(action)


func _apply_actions(mx: float, my: float, jump: bool, crouch: bool, capb: bool) -> void:
	# Analog stick (ui_*): the SMO moveset steers from these; harmless for sm64.
	# NOTE: the core's stick frame is mirrored vs the Godot camera
	# (right=(cos,-sin) is left-handed in xz), so the x axis is negated
	# here to make stick-right move camera-right.
	_set_action(&"ui_right", maxf(0.0, -mx))
	_set_action(&"ui_left", maxf(0.0, mx))
	_set_action(&"ui_up", maxf(0.0, my))
	_set_action(&"ui_down", maxf(0.0, -my))
	# sm64 directionals: world-locked actions, so rotate the stick into the
	# camera frame here (move.json has no camera_relative states).
	var s := sin(_phi)
	var c := cos(_phi)
	var wx := c * mx - s * my
	var wz := -s * mx - c * my
	_set_action(&"ff_right", maxf(0.0, wx))
	_set_action(&"ff_left", maxf(0.0, -wx))
	_set_action(&"ff_fwd", maxf(0.0, -wz))
	_set_action(&"ff_back", maxf(0.0, wz))
	_set_btn(&"jump", jump)
	_set_btn(&"ff_jump", jump)
	_set_btn(&"crouch", crouch)
	_set_btn(&"cap", capb)


func _physics_process(delta: float) -> void:
	var li: Dictionary = test_input if not test_input.is_empty() else _read_devices()
	if bool(li.get("menu", false)) or Input.is_action_just_pressed("ui_cancel"):
		get_tree().change_scene_to_file("res://menu.tscn")
		return
	if Input.is_physical_key_pressed(KEY_F3) and not _f3_held:
		debug_log_states = not debug_log_states
		print("[DEBUG] state transition log: ", "ON" if debug_log_states else "OFF")
	_f3_held = Input.is_physical_key_pressed(KEY_F3)
	var cam := float(li.get("cam", 0.0))
	if absf(cam) > DEADZONE:
		_phi -= cam * CAM_SENS * delta
	_apply_actions(float(li.get("mx", 0.0)), float(li.get("my", 0.0)),
		bool(li.get("jump", false)), bool(li.get("crouch", false)), bool(li.get("cap", false)))
	# Stick-up = away from camera: core maps set_stick(0,1) to
	# (sin(yaw), cos(yaw)); camera forward is (-sin(phi), -cos(phi)).
	_player.camera_yaw_deg = rad_to_deg(_phi) + 180.0
	# Probe: distance to ground below (for ground-pound entry, etc.).
	# The behavior expects ground.dist in native units (cm for SMO).
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(
		_player.position + Vector3(0, 0.5 * _unit, 0),
		_player.position + Vector3(0, -200.0 * _unit, 0))
	q.exclude = [_player.get_rid()]
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		_player.set_param("ground.dist", 99999.0)
	else:
		var dist: float = _player.position.y - (hit["position"] as Vector3).y
		_player.set_param("ground.dist", dist)
	var d: Vector3 = _player.tick()
	# move.json has no fall state: add gravity when airborne and the
	# behavior isn't driving vertical itself (jump arcs unaffected).
	if _moveset == "sm64" and not _player.is_on_floor() and absf(d.y) < 0.0001:
		_grav_v = maxf(_grav_v - 28.0 * _unit * delta, -50.0 * _unit)
		_player.velocity = Vector3(0, _grav_v, 0)
		_player.move_and_slide()
	else:
		_grav_v = 0.0
	_animator.advance(delta)
	_rig.rotation.y = _phi
	_rig.position = _rig.position.lerp(_player.position + Vector3(0, 1.4 * _unit, 0), 0.12)
	if _player.position.y < -20.0 * _unit:
		_player.position = SPAWN * _unit
		_rig.position = _player.position + Vector3(0, 1.4 * _unit, 0)
