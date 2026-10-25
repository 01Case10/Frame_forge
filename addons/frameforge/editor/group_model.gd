@tool
extends RefCounted
## Grouping + shared-rule analysis for the grouped sub-machine view.
##
## A "group" is a superstate: states carry an authored FrameState.group_name;
## when empty, the group is derived from the state name (taxonomy below,
## tuned for locomotion machines like the SMO transcription).
##
## A transition row is a "shared rule" when the identical row (same
## serialized condition + same target) appears on at least
## SHARED_MIN_SOURCES distinct states — e.g. the water-entry rule stamped
## onto every airborne state. Shared rows are counted once in the grouped
## view instead of being drawn per state.
##
## Pure functions over a SubStateMachine; no UI state. All dictionaries use
## String keys (state/group names), never StringName, to keep lookups sane.

const SHARED_MIN_SOURCES := 5

const _REACTION_STATES := ["dead", "held", "knockback", "knockback_land",
		"pit_fall", "pit_recover", "bonk"]
const _CLIMB_PREFIXES := ["pole_", "ledge_", "ceiling_", "wall_"]
const _AIR_PREFIXES := ["jump", "fall", "coyote", "land_", "bounce_", "gp_",
		"spindrill", "dive"]


static func derive_group(state_name: String) -> String:
	if state_name == "wall_push":
		return "Ground"
	if state_name.begins_with("water_"):
		return "Water"
	if state_name.begins_with("cap_") or state_name == "vault":
		return "Cap"
	for p in _CLIMB_PREFIXES:
		if state_name.begins_with(p):
			return "Climb"
	if state_name == "jump_wall":
		return "Climb"
	if _REACTION_STATES.has(state_name):
		return "Reaction"
	for p in _AIR_PREFIXES:
		if state_name.begins_with(p):
			return "Air"
	return "Ground"


static func group_of(s: FrameState) -> String:
	if s == null:
		return "Ground"
	if not s.group_name.is_empty():
		return s.group_name
	return derive_group(s.state_name)


static func members(machine: SubStateMachine, group: String) -> Array:
	var out: Array = []
	for s in machine.states:
		if s != null and group_of(s) == group:
			out.append(s)
	return out


## Group names in display order: the entry state's group first, then by
## total incident flow (descending), then alphabetically.
static func group_names(machine: SubStateMachine, analysis: Dictionary) -> Array:
	var seen := {}
	for s in machine.states:
		if s != null:
			seen[group_of(s)] = true
	var names: Array = seen.keys()
	var entry_group := ""
	if machine.entry_state != null:
		entry_group = group_of(machine.entry_state)
	var flow := {}
	for g in names:
		flow[g] = 0
	for key in analysis.get("flows_local", {}).keys():
		var parts: PackedStringArray = key.split("|")
		flow[parts[0]] = int(flow.get(parts[0], 0)) + int(analysis["flows_local"][key])
		flow[parts[1]] = int(flow.get(parts[1], 0)) + int(analysis["flows_local"][key])
	for key in analysis.get("flows_shared", {}).keys():
		var parts: PackedStringArray = key.split("|")
		flow[parts[0]] = int(flow.get(parts[0], 0)) + int(analysis["flows_shared"][key])
		flow[parts[1]] = int(flow.get(parts[1], 0)) + int(analysis["flows_shared"][key])
	names.sort_custom(func(a: String, b: String) -> bool:
		if a == entry_group:
			return true
		if b == entry_group:
			return false
		if int(flow.get(a, 0)) != int(flow.get(b, 0)):
			return int(flow.get(a, 0)) > int(flow.get(b, 0))
		return a < b)
	return names


static func row_key(row: FFTransition) -> String:
	return JSON.stringify(BehaviorJSON.condition_to_dict(row.condition)) \
			+ "|" + String(row.target_state_name)


static func find_state(machine: SubStateMachine, state_name: String) -> FrameState:
	for s in machine.states:
		if s != null and s.state_name == state_name:
			return s
	return null


## The state the grouped detail view treats as the group's entry: the
## machine entry when it lives here, else the state most targeted from
## outside the group, else the most targeted overall, else the first member.
static func group_entry(machine: SubStateMachine, group: String,
		analysis: Dictionary) -> FrameState:
	var mem := members(machine, group)
	if mem.is_empty():
		return null
	if machine.entry_state != null and group_of(machine.entry_state) == group:
		return machine.entry_state
	var outside_in := {}
	var total_in := {}
	for s in machine.states:
		if s == null:
			continue
		for row in s.transitions:
			if row == null or String(row.target_state_name).is_empty():
				continue
			var t := String(row.target_state_name)
			total_in[t] = int(total_in.get(t, 0)) + 1
			if group_of(s) != group:
				outside_in[t] = int(outside_in.get(t, 0)) + 1
	var best: FrameState = mem[0]
	var best_score := -1
	for s in mem:
		var score := int(outside_in.get(s.state_name, 0)) * 1000 \
				+ int(total_in.get(s.state_name, 0))
		if score > best_score:
			best_score = score
			best = s
	return best


## One pass over every row of the machine. Returns:
##   shared_keys    {row_key: true} for rows classified as shared rules
##   in_shared      {state_name: int} shared rows targeting the state
##   out_shared     {state_name: int} shared rows carried by the state
##   flows_local    {"From|To": int} cross-group local row counts
##   flows_shared   {"From|To": int} cross-group shared row counts
##   internal_local {group: int} local rows inside the group
##   internal_shared{group: int} shared rows inside the group
##   exits_local    {group: {to_group: int}}, exits_shared likewise
##   entries_local  {group: {from_group: int}}, entries_shared likewise
static func analyze(machine: SubStateMachine) -> Dictionary:
	var fam_sources := {}  # row_key -> {state_name: true}
	var fam_target := {}  # row_key -> target state name
	for s in machine.states:
		if s == null:
			continue
		for row in s.transitions:
			if row == null or String(row.target_state_name).is_empty():
				continue
			var k := row_key(row)
			if not fam_sources.has(k):
				fam_sources[k] = {}
				fam_target[k] = String(row.target_state_name)
			(fam_sources[k] as Dictionary)[s.state_name] = true
	var shared_keys := {}
	for k in fam_sources.keys():
		if (fam_sources[k] as Dictionary).size() >= SHARED_MIN_SOURCES:
			shared_keys[k] = true

	var out_a := {
		"shared_keys": shared_keys,
		"in_shared": {}, "out_shared": {},
		"flows_local": {}, "flows_shared": {},
		"internal_local": {}, "internal_shared": {},
		"exits_local": {}, "exits_shared": {},
		"entries_local": {}, "entries_shared": {},
	}
	for s in machine.states:
		if s == null:
			continue
		var ga := group_of(s)
		for row in s.transitions:
			if row == null or String(row.target_state_name).is_empty():
				continue
			var target_name := String(row.target_state_name)
			var target := find_state(machine, target_name)
			if target == null:
				continue
			var gb := group_of(target)
			var shared: bool = shared_keys.has(row_key(row))
			if shared:
				out_a["in_shared"][target_name] = int(out_a["in_shared"].get(target_name, 0)) + 1
				out_a["out_shared"][s.state_name] = int(out_a["out_shared"].get(s.state_name, 0)) + 1
			if ga == gb:
				var bucket: Dictionary = out_a["internal_shared" if shared else "internal_local"]
				bucket[ga] = int(bucket.get(ga, 0)) + 1
			else:
				var fbucket: Dictionary = out_a["flows_shared" if shared else "flows_local"]
				var fk := ga + "|" + gb
				fbucket[fk] = int(fbucket.get(fk, 0)) + 1
				var xbucket: Dictionary = out_a["exits_shared" if shared else "exits_local"]
				if not xbucket.has(ga):
					xbucket[ga] = {}
				(xbucket[ga] as Dictionary)[gb] = int((xbucket[ga] as Dictionary).get(gb, 0)) + 1
				var nbucket: Dictionary = out_a["entries_shared" if shared else "entries_local"]
				if not nbucket.has(gb):
					nbucket[gb] = {}
				(nbucket[gb] as Dictionary)[ga] = int((nbucket[gb] as Dictionary).get(ga, 0)) + 1
	return out_a


## Rows of `s` that the detail view draws as edges: local (non-shared),
## with a non-empty target inside `group`. Returns [{row, target}].
static func drawn_rows(machine: SubStateMachine, s: FrameState, group: String,
		analysis: Dictionary) -> Array:
	var out: Array = []
	var shared_keys: Dictionary = analysis.get("shared_keys", {})
	for row in s.transitions:
		if row == null or String(row.target_state_name).is_empty():
			continue
		if shared_keys.has(row_key(row)):
			continue
		var target := find_state(machine, String(row.target_state_name))
		if target != null and group_of(target) == group:
			out.append({"row": row, "target": target})
	return out
