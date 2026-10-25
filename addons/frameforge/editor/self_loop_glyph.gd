@tool
extends Control
## Round self-loop glyph for the grouped detail graph: drawn in the row
## of a transition whose target is its own state, in place of a
## GraphEdit self-connection (which renders as an unreadable curl —
## out-port on the right, in-port on the left, one node width apart).
## A near-full circle with an arrowhead: reads as "loops to itself" at
## a glance and travels with the node for free.

const COL_EDGE := Color(0.72, 0.75, 0.80)


func _init() -> void:
	custom_minimum_size = Vector2(36, 21)
	mouse_filter = MOUSE_FILTER_IGNORE


func _draw() -> void:
	var c := Vector2(size.x - 13.0, size.y * 0.5)
	var r := 8.0
	# Sweep ~310 degrees, leaving a gap where the arrowhead lands.
	var a0 := -0.30 * PI
	var a1 := a0 + 1.72 * PI
	draw_arc(c, r, a0, a1, 32, COL_EDGE, 2.0, true)
	var radial := Vector2(cos(a1), sin(a1))
	var tip := c + radial * r
	var tangent := Vector2(-sin(a1), cos(a1))
	draw_colored_polygon(PackedVector2Array([
		tip + tangent * 5.4,
		tip - tangent * 1.6 + radial * 3.8,
		tip - tangent * 1.6 - radial * 3.8,
	]), COL_EDGE)
