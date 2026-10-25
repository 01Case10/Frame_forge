extends SceneTree
## Dumps Godot Curve::sample ground truth for the Rust port spot-check table.
## Usage: godot --headless --path . --script res://exit_gate/sample_curve.gd -- --out /tmp/curve_truth.json

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var out: String = args[args.find("--out") + 1] if "--out" in args else "/tmp/curve_truth.json"
	var cases := {}

	# 1. Flat default easing (2 pts, zero tangents).
	var c1 := Curve.new()
	c1.add_point(Vector2(0, 1))
	c1.add_point(Vector2(1, 1))
	cases["flat"] = _dump(c1, [0.0, 0.25, 0.5, 0.75, 1.0, -0.1, 1.1])

	# 2. Linear ramp via TANGENT_LINEAR (like _fit_curve).
	var c2 := Curve.new()
	c2.add_point(Vector2(0, 0), 0, 0, Curve.TANGENT_LINEAR, Curve.TANGENT_LINEAR)
	c2.add_point(Vector2(0.5, 0.5), 0, 0, Curve.TANGENT_LINEAR, Curve.TANGENT_LINEAR)
	c2.add_point(Vector2(1, 1), 0, 0, Curve.TANGENT_LINEAR, Curve.TANGENT_LINEAR)
	cases["linear3"] = _dump(c2, [0.0, 0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875, 1.0])
	cases["linear3_tangents"] = _tangents(c2)

	# 3. Smooth (default zero tangents) 3-pt curve — exercises cubic Bezier.
	var c3 := Curve.new()
	c3.add_point(Vector2(0, 0))
	c3.add_point(Vector2(0.5, 1))
	c3.add_point(Vector2(1, 0))
	cases["smooth3"] = _dump(c3, [0.0, 0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875, 1.0])

	# 4. Explicit non-zero tangents.
	var c4 := Curve.new()
	c4.add_point(Vector2(0, 0), 0.0, 2.0)
	c4.add_point(Vector2(1, 1), -1.0, 0.0)
	cases["explicit_tan"] = _dump(c4, [0.0, 0.25, 0.5, 0.75, 1.0])
	cases["explicit_tan_tangents"] = _tangents(c4)

	# 5. Clamping: values outside [min_value, max_value].
	var c5 := Curve.new()
	c5.add_point(Vector2(0, -0.5))
	c5.add_point(Vector2(1, 1.5))
	cases["clamp_default"] = _dump(c5, [0.0, 0.25, 0.5, 0.75, 1.0])
	var c5b := Curve.new()
	c5b.min_value = -2.0
	c5b.max_value = 2.0
	c5b.add_point(Vector2(0, -0.5))
	c5b.add_point(Vector2(1, 1.5))
	cases["clamp_wide"] = _dump(c5b, [0.0, 0.5, 1.0])

	# 6. Does add_point clamp y into [min_value, max_value]?
	var c6 := Curve.new()  # default 0..1
	c6.add_point(Vector2(0.5, 2.0))
	var p6 := c6.get_point_position(0)
	cases["add_point_clamp"] = {"stored_y": p6.y, "min": c6.min_value, "max": c6.max_value}

	# 7. Out-of-range offsets.
	var c7 := Curve.new()
	c7.add_point(Vector2(0.2, 0.3))
	c7.add_point(Vector2(0.8, 0.9))
	cases["out_of_range"] = _dump(c7, [-1.0, 0.0, 0.2, 0.5, 0.8, 1.0, 2.0])

	# 8. Empty curve.
	var c8 := Curve.new()
	cases["empty"] = _dump(c8, [0.0, 0.5, 1.0])

	# 9. Single point.
	var c9 := Curve.new()
	c9.add_point(Vector2(0.4, 0.7))
	cases["single"] = _dump(c9, [0.0, 0.4, 0.7, 1.0])

	var f := FileAccess.open(out, FileAccess.WRITE)
	f.store_string(JSON.stringify(cases, "  "))
	f.close()
	print("wrote ", out)
	quit()


func _dump(c: Curve, offsets: Array) -> Dictionary:
	var d := {}
	for o in offsets:
		d[str(o)] = c.sample(float(o))
	return {"samples": d, "min": c.min_value, "max": c.max_value, "count": c.get_point_count()}


func _tangents(c: Curve) -> Array:
	var a := []
	for i in c.get_point_count():
		var p := c.get_point_position(i)
		a.append({"pos": [p.x, p.y], "lt": c.get_point_left_tangent(i), "rt": c.get_point_right_tangent(i)})
	return a
