extends SceneTree
## One-shot exporter: FrameBehavior .tres -> canonical JSON for the Rust core.
## Usage:
##   godot --headless --path . --script res://exit_gate/export_json.gd -- --all
##   godot --headless --path . --script res://exit_gate/export_json.gd -- --in res://exit_gate/behaviors/walk.tres --out /tmp/walk.json

const OUT_DIR := "rust/behaviors"

const DIR_SOURCE := ["author", "impact_normal", "reflected", "input", "entry"]
const DISP_SOURCE := ["author", "incoming", "entry"]
const INPUT_PLANE := ["xz", "xy"]
const COND_TYPE := ["on_complete", "on_input", "on_variable", "on_event", "on_state", "on_custom"]
const INPUT_MODE := ["any_pressed", "any_released", "all_released", "any_held"]
const OP := ["eq", "ne", "gt", "ge", "lt", "le"]
const MOMENTUM := ["cut", "preserve"]
const PTYPE := ["bool", "int", "float", "string"]
const TRIGGER := ["on_enter", "on_exit", "on_frame"]


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if "--all" in args:
		_export_all()
	elif "--in" in args and "--out" in args:
		var src: String = args[args.find("--in") + 1]
		var dst: String = args[args.find("--out") + 1]
		_export_one(src, dst)
	else:
		print("usage: -- --all | --in <tres> --out <json>")
	quit()


func _export_all() -> void:
	var pairs: Array = []
	var d := DirAccess.open("res://exit_gate/behaviors")
	for f in d.get_files():
		if f.ends_with(".tres"):
			pairs.append(["res://exit_gate/behaviors/" + f, f.replace(".tres", ".json")])
	var b := DirAccess.open("res://exit_gate/baked")
	for f in b.get_files():
		if f.ends_with("_chain.tres") or f == "triple_jump_baked.tres":
			pairs.append(["res://exit_gate/baked/" + f, f.replace(".tres", ".json")])
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://" + OUT_DIR))
	for p in pairs:
		_export_one(p[0], ProjectSettings.globalize_path("res://" + OUT_DIR + "/" + p[1]))


func _export_one(src: String, dst: String) -> void:
	var bh: FrameBehavior = load(src)
	if bh == null:
		push_error("cannot load " + src)
		return
	var dict := _behavior_dict(bh)
	var text := JSON.stringify(dict, "  ")
	var f := FileAccess.open(dst, FileAccess.WRITE)
	f.store_string(text)
	f.close()
	print("exported ", src, " -> ", dst)


func _behavior_dict(bh: FrameBehavior) -> Dictionary:
	var machines := []
	for m in bh.sub_machines:
		machines.append(_machine_dict(m))
	var params := []
	for p in bh.parameters:
		params.append({
			"name": p.name,
			"ptype": PTYPE[p.ptype],
			"default_value": p.default_value,
		})
	var btrs := []
	for t in bh.behavior_transitions:
		btrs.append(_transition_dict(t))
	return {
		"behavior_name": bh.behavior_name,
		"sub_machines": machines,
		"parameters": params,
		"behavior_transitions": btrs,
		"on_enter_event": bh.on_enter_event,
		"on_exit_event": bh.on_exit_event,
	}


func _machine_dict(m: SubStateMachine) -> Dictionary:
	var states := []
	for s in m.states:
		states.append(_state_dict(s))
	var comments := []
	for c in m.editor_comments:
		comments.append({
			"title": c.title,
			"position": [c.position.x, c.position.y],
			"size": [c.size.x, c.size.y],
			"tint": [c.tint.r, c.tint.g, c.tint.b, c.tint.a],
		})
	return {
		"machine_name": m.machine_name,
		"states": states,
		"entry_state_name": m.entry_state.state_name if m.entry_state != null else "",
		"default_resp_floor": _resp_dict(m.default_resp_floor),
		"default_resp_ceiling": _resp_dict(m.default_resp_ceiling),
		"default_resp_wall": _resp_dict(m.default_resp_wall),
		"editor_comments": comments,
	}


func _resp_dict(r: FFResponse) -> Variant:
	if r == null:
		return null
	return {
		"target_state_name": String(r.target_state_name),
		"target_behavior_name": r.target_behavior.behavior_name if r.target_behavior != null else "",
		"min_incoming_speed": r.min_incoming_speed,
		"rearm_ticks": r.rearm_ticks,
	}


func _state_dict(s: FrameState) -> Dictionary:
	var events := []
	for e in s.events:
		events.append({
			"event_name": e.event_name,
			"trigger": TRIGGER[e.trigger],
			"frame": e.frame,
		})
	var trs := []
	for t in s.transitions:
		trs.append(_transition_dict(t))
	return {
		"state_name": s.state_name,
		"displacement": s.displacement,
		"direction": [s.direction.x, s.direction.y, s.direction.z],
		"duration_frames": s.duration_frames,
		"easing": _curve_dict(s.easing),
		"direction_source": DIR_SOURCE[s.direction_source],
		"displacement_source": DISP_SOURCE[s.displacement_source],
		"restitution": s.restitution,
		"input_left": s.input_left,
		"input_right": s.input_right,
		"input_forward": s.input_forward,
		"input_back": s.input_back,
		"input_plane": INPUT_PLANE[s.input_plane],
		"input_deadzone": s.input_deadzone,
		"camera_relative": s.camera_relative,
		"input_turn_rate_deg": s.input_turn_rate_deg,
		"resp_floor": _resp_dict(s.resp_floor),
		"resp_ceiling": _resp_dict(s.resp_ceiling),
		"resp_wall": _resp_dict(s.resp_wall),
		"events": events,
		"transitions": trs,
		"editor_position": [s.editor_position.x, s.editor_position.y],
	}


func _curve_dict(c: Curve) -> Dictionary:
	if c == null:
		return {"points": [], "min_value": 0.0, "max_value": 1.0}
	var pts := []
	for i in c.get_point_count():
		var p := c.get_point_position(i)
		pts.append({
			"pos": [p.x, p.y],
			"left_tangent": c.get_point_left_tangent(i),
			"right_tangent": c.get_point_right_tangent(i),
		})
	return {"points": pts, "min_value": c.min_value, "max_value": c.max_value}


func _transition_dict(t: FFTransition) -> Dictionary:
	var cond := {}
	if t.condition != null:
		var c: FFCondition = t.condition
		var actions := []
		for a in c.input_actions:
			actions.append(String(a))
		cond = {
			"type": COND_TYPE[c.type],
			"input_actions": actions,
			"input_mode": INPUT_MODE[c.input_mode],
			"param_name": c.param_name,
			"param_op": OP[c.param_op],
			"param_value": c.param_value,
			"event_name": c.event_name,
			"target_machine_name": String(c.target_machine_name),
			"target_state_name": String(c.target_state_name),
			"custom_name": String(c.custom_name),
		}
	return {
		"condition": cond,
		"target_state_name": String(t.target_state_name),
		"target_behavior_name": t.target_behavior.behavior_name if t.target_behavior != null else "",
		"momentum": MOMENTUM[t.momentum],
		"blend_frames": t.blend_frames,
		"fire_event": t.fire_event,
		"silent": t.silent,
	}
