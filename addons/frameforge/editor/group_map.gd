@tool
extends Control
## Grouped view, top level: one UE-style state card per superstate with
## aggregated flows between them. Lines are uniform (Unreal language);
## the count chips carry the kind — gold text counts shared-rule
## transitions once, not per state. Clicking a card selects the group
## shown in the detail graph below.

signal group_selected(group_name: String)

const GroupModel := preload("res://addons/frameforge/editor/group_model.gd")
const UEStyle := preload("res://addons/frameforge/editor/ue_style.gd")

## Golden ratio, used for the box gaps below.
const PHI := 1.618034

const COL_FLOW := Color(0.72, 0.75, 0.80, 0.85)
const COL_FAINT := Color(0.42, 0.43, 0.46)
const COL_CHIP := Color(0.10, 0.10, 0.11, 0.92)

# (row, col) slots on a 3-column grid, in assignment order: middle row
# first (entry group lands left-center), then top corners, bottom center.
const SLOTS_3COL := [[1, 0], [1, 1], [1, 2], [0, 0], [0, 2], [2, 1],
		[2, 0], [2, 2], [0, 1]]

var _machine: SubStateMachine = null
var _analysis: Dictionary = {}
var _groups: Array = []
var _boxes := {}  # group name -> Rect2
var _slot_of := {}  # group name -> slot index (beautify rearranges these)
var _selected := ""
var _hover := ""
var _chip_box: StyleBoxFlat
var _bold: Font = null


func _bold_font() -> Font:
	if _bold == null:
		_bold = UEStyle.bold_font(get_theme_default_font())
	return _bold


func _init() -> void:
	_chip_box = StyleBoxFlat.new()
	_chip_box.bg_color = COL_CHIP
	_chip_box.corner_radius_top_left = 8
	_chip_box.corner_radius_top_right = 8
	_chip_box.corner_radius_bottom_left = 8
	_chip_box.corner_radius_bottom_right = 8
	custom_minimum_size = Vector2(0, 380)
	mouse_filter = MOUSE_FILTER_STOP


func setup(machine: SubStateMachine, analysis: Dictionary) -> void:
	_machine = machine
	_analysis = analysis
	_groups = GroupModel.group_names(machine, analysis)
	_slot_of.clear()
	queue_redraw()


func set_selected(group: String) -> void:
	_selected = group
	queue_redraw()


func _notification(what: int) -> void:
	# Box layout derives from the current size; without this the map can
	# keep boxes computed for a pre-layout size (e.g. when the grouped
	# view is opened while the editor is still arranging docks).
	if what == NOTIFICATION_RESIZED:
		queue_redraw()


func refresh() -> void:
	if _machine != null:
		_analysis = GroupModel.analyze(_machine)
		_groups = GroupModel.group_names(_machine, _analysis)
		_slot_of.clear()
	queue_redraw()


# ------------------------------------------------------------------ layout ---

func _compute_boxes() -> void:
	_ensure_slots()
	_boxes = _layout_boxes(_slot_of)


func _ensure_slots() -> void:
	var valid := _slot_of.size() == _groups.size()
	if valid:
		for g in _groups:
			if not _slot_of.has(g):
				valid = false
				break
	if not valid:
		_slot_of.clear()
		for i in _groups.size():
			_slot_of[_groups[i]] = i


## Box rects for a group -> slot assignment. Boxes sit centered in grid
## cells, so they can never overlap regardless of the slot assignment;
## the box width follows the golden ratio on the gaps (horizontal gap
## between boxes : vertical gap = PHI : 1, floored so a narrow map
## still gets usable boxes). No width cap: a cap would break the ratio
## whenever the cell is wider than the cap plus the golden gap.
func _layout_boxes(assign: Dictionary) -> Dictionary:
	var out := {}
	var n := _groups.size()
	if n == 0:
		return out
	var cols := 3 if n <= 9 else (4 if n <= 16 else 5)
	var rows := 3 if cols == 3 else int(ceil(float(n) / cols))
	var cell := Vector2(size.x / cols, size.y / rows)
	var bh: float = minf(cell.y - 30.0, 116.0)
	var bw: float = maxf(cell.x - PHI * (cell.y - bh), 120.0)
	for g in _groups:
		var idx := int(assign.get(g, 0))
		var rc: Array
		if cols == 3:
			rc = SLOTS_3COL[idx]
		else:
			rc = [idx / cols, idx % cols]
		var origin := Vector2(rc[1] * cell.x, rc[0] * cell.y)
		out[g] = Rect2(origin + (cell - Vector2(bw, bh)) * 0.5, Vector2(bw, bh))
	return out


func _border_point(rect: Rect2, toward: Vector2) -> Vector2:
	var c := rect.get_center()
	var d := toward - c
	if d == Vector2.ZERO:
		return c
	if absf(d.x) / rect.size.x > absf(d.y) / rect.size.y:
		return Vector2(c.x + rect.size.x * 0.5 * signf(d.x),
				c.y + d.y / absf(d.x) * rect.size.x * 0.5)
	return Vector2(c.x + d.x / absf(d.y) * rect.size.y * 0.5,
			c.y + rect.size.y * 0.5 * signf(d.y))


# ------------------------------------------------------------------ drawing ---

func _draw() -> void:
	if _machine == null:
		return
	# UE canvas: near-black with a subtle grid.
	draw_rect(Rect2(Vector2.ZERO, size), UEStyle.BG)
	var grid_col := Color(1, 1, 1, 0.045)
	var gx := 28.0
	while gx < size.x:
		draw_line(Vector2(gx, 0), Vector2(gx, size.y), grid_col, 1.0)
		gx += 28.0
	var gy := 28.0
	while gy < size.y:
		draw_line(Vector2(0, gy), Vector2(size.x, gy), grid_col, 1.0)
		gy += 28.0
	_compute_boxes()
	_draw_flows(_analysis.get("flows_local", {}), false)
	_draw_flows(_analysis.get("flows_shared", {}), true)
	for g in _groups:
		_draw_box(g, _boxes[g])
	# Count chips last so boxes never paint over them.
	_draw_flow_labels(_analysis.get("flows_local", {}), false)
	_draw_flow_labels(_analysis.get("flows_shared", {}), true)


## Geometry for one flow pass: [{pts, ctrl, label, shared, from, to}].
func _flow_geometry(flows: Dictionary, shared: bool, boxes: Dictionary,
		samples := 25) -> Array:
	var out: Array = []
	# Shared flows: only the largest few, or the map drowns in gold.
	var keys: Array = flows.keys()
	keys.sort_custom(func(a: String, b: String) -> bool:
		return int(flows[a]) > int(flows[b]))
	var limit := keys.size() if not shared else mini(keys.size(), 4)
	var local_flows: Dictionary = _analysis.get("flows_local", {})
	for i in limit:
		var key: String = keys[i]
		var parts := key.split("|")
		if not boxes.has(parts[0]) or not boxes.has(parts[1]):
			continue
		var ra: Rect2 = boxes[parts[0]]
		var rb: Rect2 = boxes[parts[1]]
		var pa := _border_point(ra, rb.get_center())
		var pb := _border_point(rb, ra.get_center())
		# Offset bidirectional pairs so the two curves separate; shared
		# curves also shift off the local curve for the same pair.
		var off := 0.0
		var reverse := parts[1] + "|" + parts[0]
		if flows.has(reverse):
			off = 18.0 if parts[0] < parts[1] else -18.0
		if shared and (local_flows.has(key) or local_flows.has(reverse)):
			off += 30.0
		var mid := (pa + pb) * 0.5
		var perp := (pb - pa).orthogonal().normalized() * off
		var ctrl := mid + perp + Vector2(0, -10)
		var pts := PackedVector2Array()
		for j in samples:
			var t := j / float(samples - 1)
			var mt := 1.0 - t
			pts.append(mt * mt * pa + 2.0 * mt * t * ctrl + t * t * pb)
		out.append({"pts": pts, "ctrl": ctrl,
				"label": ("shared ×%d" if shared else "×%d") % int(flows[key]),
				"shared": shared, "from": parts[0], "to": parts[1]})
	return out


func _draw_flows(flows: Dictionary, _shared: bool) -> void:
	# Uniform UE lines for both kinds; the chips carry the distinction.
	for e in _flow_geometry(flows, _shared, _boxes):
		var pts: PackedVector2Array = e["pts"]
		draw_polyline(pts, COL_FLOW, 1.8)
		var dir := (pts[pts.size() - 1] - pts[pts.size() - 3]).normalized()
		var tip := pts[pts.size() - 1]
		var side := dir.orthogonal() * 5.0
		draw_colored_polygon(PackedVector2Array(
				[tip, tip - dir * 11.0 + side, tip - dir * 11.0 - side]), COL_FLOW)


func _draw_flow_labels(flows: Dictionary, shared: bool) -> void:
	var font := get_theme_default_font()
	for e in _flow_geometry(flows, shared, _boxes):
		var label: String = e["label"]
		var ctrl: Vector2 = e["ctrl"]
		var tw := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
		var chip := Rect2(ctrl - Vector2(tw * 0.5 + 6, 19), Vector2(tw + 12, 17))
		_chip_box.draw(get_canvas_item(), chip)
		draw_string(font, chip.position + Vector2(6, 13), label,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 12,
				UEStyle.GOLD if shared else UEStyle.INK)


func _draw_box(g: String, rect: Rect2) -> void:
	var font := get_theme_default_font()
	var selected := g == _selected
	var box := StyleBoxFlat.new()
	box.bg_color = UEStyle.CARD
	box.border_color = UEStyle.SELECT if selected else UEStyle.CARD_BORDER
	box.set_border_width_all(2 if selected else 1)
	box.set_corner_radius_all(10)
	box.shadow_color = Color(0, 0, 0, 0.4)
	box.shadow_size = 8
	box.shadow_offset = Vector2(0, 2)
	box.draw(get_canvas_item(), rect)
	var x := rect.position.x + 12
	var top := rect.position.y
	draw_string(_bold_font(), Vector2(x, top + 22), g.to_upper(),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 15, UEStyle.INK)
	var tag := "expanded ↓" if selected else "▸ expand"
	var tw := font.get_string_size(tag, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
	draw_string(font, Vector2(rect.position.x + rect.size.x - 12 - tw, top + 20),
			tag, HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
			UEStyle.SELECT if selected else UEStyle.SUB)
	var mem := GroupModel.members(_machine, g)
	var internal := int((_analysis.get("internal_local", {}) as Dictionary).get(g, 0)) \
			+ int((_analysis.get("internal_shared", {}) as Dictionary).get(g, 0))
	draw_string(font, Vector2(x, top + 50),
			"%d states · %d internal edges" % [mem.size(), internal],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, UEStyle.SUB)
	var names := ""
	for i in mini(4, mem.size()):
		names += (", " if i > 0 else "") + (mem[i] as FrameState).state_name
	if mem.size() > 4:
		names += ", …"
	while font.get_string_size(names, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x > rect.size.x - 24 and names.length() > 8:
		names = names.left(names.length() - 2)
	draw_string(font, Vector2(x, top + 70), names,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, COL_FAINT)
	var entry := GroupModel.group_entry(_machine, g, _analysis)
	draw_string(font, Vector2(x, top + 88),
			"entry: " + (entry.state_name if entry != null else "—"),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, COL_FAINT)


# ------------------------------------------------------------------ beautify ---

## Count intersections between drawn flow curves (pairs sharing a box are
## skipped — their curves meet at the border by construction).
func _eval_crossings(boxes: Dictionary) -> int:
	var curves: Array = []
	for e in _flow_geometry(_analysis.get("flows_local", {}), false, boxes, 9):
		curves.append(e)
	for e in _flow_geometry(_analysis.get("flows_shared", {}), true, boxes, 9):
		curves.append(e)
	var total := 0
	for i in curves.size():
		for j in range(i + 1, curves.size()):
			var ci: Dictionary = curves[i]
			var cj: Dictionary = curves[j]
			if ci["from"] == cj["from"] or ci["from"] == cj["to"] \
					or ci["to"] == cj["from"] or ci["to"] == cj["to"]:
				continue
			var p: PackedVector2Array = ci["pts"]
			var q: PackedVector2Array = cj["pts"]
			for a in p.size() - 1:
				for b in q.size() - 1:
					if _seg_intersect(p[a], p[a + 1], q[b], q[b + 1]):
						total += 1
	return total


static func _seg_intersect(p1: Vector2, p2: Vector2, p3: Vector2, p4: Vector2) -> bool:
	var d1 := (p4 - p3).cross(p1 - p3)
	var d2 := (p4 - p3).cross(p2 - p3)
	var d3 := (p2 - p1).cross(p3 - p1)
	var d4 := (p2 - p1).cross(p4 - p1)
	return ((d1 > 0.0 and d2 < 0.0) or (d1 < 0.0 and d2 > 0.0)) \
			and ((d3 > 0.0 and d4 < 0.0) or (d3 < 0.0 and d4 > 0.0))


## Rearrange the group boxes among the layout slots to minimize flow
## crossings: exhaustive over slot permutations up to 6 groups,
## swap hill-climbing beyond that. Returns {"before", "after"}.
func beautify() -> Dictionary:
	var n := _groups.size()
	if n < 2 or size.x < 10.0:
		return {"before": 0, "after": 0}
	_ensure_slots()
	_compute_boxes()
	var before := _eval_crossings(_boxes)
	var best := before
	var best_assign := _slot_of.duplicate()
	if n <= 6:
		var perms: Array = []
		var slots: Array = []
		for i in n:
			slots.append(i)
		_perm_rec(slots, 0, perms)
		for perm in perms:
			var assign := {}
			for i in n:
				assign[_groups[i]] = int(perm[i])
			var score := _eval_crossings(_layout_boxes(assign))
			if score < best:
				best = score
				best_assign = assign
	else:
		var rng := RandomNumberGenerator.new()
		rng.seed = 12345
		var cur := best_assign.duplicate()
		var cur_score := best
		for it in 400:
			var i := rng.randi_range(0, n - 1)
			var j := rng.randi_range(0, n - 1)
			if i == j:
				continue
			var cand := cur.duplicate()
			var gi: String = _groups[i]
			var gj: String = _groups[j]
			var tmp = cand[gi]
			cand[gi] = cand[gj]
			cand[gj] = tmp
			var score := _eval_crossings(_layout_boxes(cand))
			if score < cur_score:
				cur_score = score
				cur = cand
		best = cur_score
		best_assign = cur
	_slot_of = best_assign
	_boxes = _layout_boxes(_slot_of)
	queue_redraw()
	return {"before": before, "after": best}


func _perm_rec(slots: Array, l: int, results: Array) -> void:
	if l >= slots.size() - 1:
		results.append(slots.duplicate())
		return
	for i in range(l, slots.size()):
		var tmp = slots[l]
		slots[l] = slots[i]
		slots[i] = tmp
		_perm_rec(slots, l + 1, results)
		tmp = slots[l]
		slots[l] = slots[i]
		slots[i] = tmp


# ------------------------------------------------------------------ input ---

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		for g in _groups:
			if (_boxes.get(g, Rect2()) as Rect2).has_point(event.position):
				_selected = g
				queue_redraw()
				group_selected.emit(g)
				accept_event()
				return
	if event is InputEventMouseMotion:
		var hov := ""
		for g in _groups:
			if (_boxes.get(g, Rect2()) as Rect2).has_point(event.position):
				hov = g
				break
		if hov != _hover:
			_hover = hov
			mouse_default_cursor_shape = CURSOR_POINTING_HAND if not hov.is_empty() else CURSOR_ARROW
			queue_redraw()
