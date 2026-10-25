## Unreal Engine AnimGraph state-machine design language, shared by all
## FrameForge editor graph surfaces (grouped map, grouped detail, flat
## graph): near-black canvas with a subtle grid, one-piece rounded state
## cards with bold white names and gray subtitles, light flat lines with
## arrowheads, circular transition badges, and orange for selection.
## Styling only — no behavior lives here.
extends RefCounted

const BG := Color(0.137, 0.137, 0.137)  # #232323
const GRID_MINOR := Color(0.165, 0.165, 0.165)
const GRID_MAJOR := Color(0.208, 0.208, 0.208)
const CARD := Color(0.110, 0.110, 0.118)
const CARD_BORDER := Color(0.230, 0.230, 0.250)
const SELECT := Color(0.960, 0.600, 0.130)  # UE selection orange
const LINE := Color(0.720, 0.750, 0.800)
const INK := Color(0.930, 0.930, 0.940)
const SUB := Color(0.550, 0.560, 0.600)
const GOLD := Color(0.850, 0.720, 0.470)
const BADGE_FILL := Color(0.130, 0.130, 0.140)


static func bold_font(base: Font) -> Font:
	var fv := FontVariation.new()
	fv.base_font = base
	fv.variation_embolden = 0.65
	return fv


static func _flat(bg: Color, border: Color, bw_t: int, bw_r: int,
		bw_b: int, bw_l: int, rtl: int, rtr: int, rbl: int,
		rbr: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.border_width_top = bw_t
	sb.border_width_right = bw_r
	sb.border_width_bottom = bw_b
	sb.border_width_left = bw_l
	sb.corner_radius_top_left = rtl
	sb.corner_radius_top_right = rtr
	sb.corner_radius_bottom_left = rbl
	sb.corner_radius_bottom_right = rbr
	sb.anti_aliasing = true
	return sb


## One-piece UE state card for a GraphNode: titlebar and panel share the
## card fill; only the outer corners are rounded and only the outer
## edges carry the border, so the seam between them disappears.
static func apply_graph_node(node: GraphNode, base_font: Font) -> void:
	var n_t := _flat(CARD, CARD_BORDER, 1, 1, 0, 1, 10, 10, 0, 0)
	n_t.content_margin_left = 12
	n_t.content_margin_right = 12
	n_t.content_margin_top = 6
	n_t.content_margin_bottom = 3
	var n_p := _flat(CARD, CARD_BORDER, 0, 1, 1, 1, 0, 0, 10, 10)
	n_p.content_margin_left = 10
	n_p.content_margin_right = 10
	n_p.content_margin_top = 4
	n_p.content_margin_bottom = 8
	var s_t := _flat(CARD, SELECT, 2, 2, 0, 2, 10, 10, 0, 0)
	s_t.content_margin_left = 12
	s_t.content_margin_right = 12
	s_t.content_margin_top = 6
	s_t.content_margin_bottom = 3
	var s_p := _flat(CARD, SELECT, 0, 2, 2, 2, 0, 0, 10, 10)
	s_p.content_margin_left = 10
	s_p.content_margin_right = 10
	s_p.content_margin_top = 4
	s_p.content_margin_bottom = 8
	node.add_theme_stylebox_override("titlebar", n_t)
	node.add_theme_stylebox_override("panel", n_p)
	node.add_theme_stylebox_override("titlebar_selected", s_t)
	node.add_theme_stylebox_override("panel_selected", s_p)
	if base_font != null:
		node.add_theme_font_override("title_font", bold_font(base_font))
	node.add_theme_color_override("title_color", INK)
	node.add_theme_font_size_override("title_font_size", 13)


## UE canvas for a GraphEdit: near-black background, subtle grid,
## orange-tinted selection rectangle.
static func apply_graph_canvas(ge: GraphEdit) -> void:
	ge.add_theme_color_override("grid_major", GRID_MAJOR)
	ge.add_theme_color_override("grid_minor", GRID_MINOR)
	var bg := StyleBoxFlat.new()
	bg.bg_color = BG
	ge.add_theme_stylebox_override("bg", bg)
	ge.add_theme_color_override("selection_fill", Color(SELECT, 0.08))
	ge.add_theme_color_override("selection_stroke", Color(SELECT, 0.55))


## Small rounded pill (map count chips, the ENTRY tag).
static func pill(bg: Color, border: Color) -> StyleBoxFlat:
	var sb := _flat(bg, border, 1, 1, 1, 1, 9, 9, 9, 9)
	sb.content_margin_left = 7
	sb.content_margin_right = 7
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	return sb
