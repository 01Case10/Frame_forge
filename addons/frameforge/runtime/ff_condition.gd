class_name FFCondition
extends Resource
## One condition on a transition row. Rows are evaluated top-to-bottom
## each tick; the first true row wins. (Evaluation lives in the Rust
## core; this resource is the editor's document model and mirrors
## frameforge-core's `Condition` struct field-for-field.)
##
## Composite rule (core semantics): when `all_of` is non-empty it defines
## the condition and `type` is ignored; otherwise a non-empty `any_of`
## defines it. Children are full conditions, recursively.
##
## On State targets are referenced BY NAME (see FFTransition for why:
## .tres cannot serialize cyclic object refs).

enum Type { ON_COMPLETE, ON_INPUT, ON_VARIABLE, ON_EVENT, ON_STATE, ON_CUSTOM, ON_STICK }
enum InputMode { ANY_PRESSED, ANY_RELEASED, ALL_RELEASED, ANY_HELD, NONE_HELD }
enum Op { EQ, NE, GT, GE, LT, LE }
enum StickAngleVs { FACING, VELOCITY }

## Core default for stick_radius_max (f32::MAX), as an f64 literal.
const STICK_RADIUS_MAX_DEFAULT := 3.4028235e38

@export var type: int = Type.ON_COMPLETE
# On Input: list of InputMap actions + edge/level mode.
@export var input_actions: PackedStringArray = []
@export var input_mode: int = InputMode.ANY_PRESSED
## G-1: for ANY_PRESSED, ticks after the press tick the press stays valid
## (0 = press tick only). A press consumed by a firing row is cleared.
@export var buffer_ticks: int = 0
# On Variable: blackboard parameter comparison.
@export var param_name: String = ""
@export var param_op: int = Op.EQ
@export var param_value: Variant = 0.0
# On Event: named event (state/transition/game/player contact-edge).
@export var event_name: String = ""
# On State: another sub-machine is in a given state.
@export var target_machine_name: StringName = &""
@export var target_state_name: StringName = &""
# On Custom: registered predicate name (the Rust core's custom-condition
# registry; the GDExtension player registers the smo.* predicates).
@export var custom_name: StringName = &""
# On Stick (G-2): analog stick radius window + angle vs a reference.
@export var stick_radius_min: float = 0.0
@export var stick_radius_max: float = STICK_RADIUS_MAX_DEFAULT
@export var stick_angle_vs: int = StickAngleVs.FACING
@export var stick_angle_min_deg: float = 0.0
@export var stick_angle_max_deg: float = 180.0
# Composites (recursive). Non-empty all_of wins over any_of wins over type.
@export var all_of: Array[FFCondition] = []
@export var any_of: Array[FFCondition] = []

## Name-resolution caches, not serialized. Populated by editor tooling
## (validator / graphs).
var resolved_machine: SubStateMachine = null
var resolved_state: FrameState = null
