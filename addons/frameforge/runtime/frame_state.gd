class_name FrameState
extends Resource
## One node of a FrameForge state machine: how far the character moves,
## in which direction, over how many 60 Hz frames.

enum DirectionSource { AUTHOR, IMPACT_NORMAL, REFLECTED, INPUT, ENTRY }
enum DisplacementSource { AUTHOR, INCOMING, ENTRY }
enum InputPlane { XZ, XY }

@export var state_name: String = "State"
@export var displacement: float = 0.0
@export var direction: Vector3 = Vector3.ZERO
@export var duration_frames: int = 1
@export var easing: Curve
@export var direction_source: int = DirectionSource.AUTHOR
@export var displacement_source: int = DisplacementSource.AUTHOR
@export var restitution: float = 1.0
# INPUT direction config (used when direction_source == INPUT).
@export var input_left: String = ""
@export var input_right: String = ""
@export var input_forward: String = ""
@export var input_back: String = ""
@export var input_plane: int = InputPlane.XZ
@export var input_deadzone: float = 0.2
@export var camera_relative: bool = false
@export var yaw_reference: NodePath = NodePath()
## Max direction change per tick in degrees (0 = instant). Models turn lag
## like SM64's 11.25 deg/frame facing approach; the lagged facing persists
## per sub-machine track.
@export var input_turn_rate_deg: float = 0.0
# Collision responses; null = inherit the sub-machine default.
@export var resp_floor: FFResponse = null
@export var resp_ceiling: FFResponse = null
@export var resp_wall: FFResponse = null
# Custom events (runtime emission: phase 3).
@export var events: Array[FFStateEvent] = []
# Ordered transition rows (see FFTransition).
@export var transitions: Array[FFTransition] = []
## G-6: name of a registered state-logic implementation (e.g. "wallrun").
## Empty = pure data state. Unknown names are a validation error.
@export var logic: String = ""
## G-4: blackboard params applied when the state is entered.
@export var enter_params: Array[FFParamAssign] = []
## G-5: per-tick steering config. Null = authored displacement x easing.
@export var steer: FFSteerConfig = null
## Editor-only: node position on the sub-machine graph canvas.
@export var editor_position := Vector2.ZERO
## Editor-only: superstate this state belongs to in the grouped view.
## Empty = derived from the state name (see editor/group_model.gd).
@export var group_name: String = ""


func _init() -> void:
	# Default easing: even distribution (flat 1.0).
	easing = Curve.new()
	easing.add_point(Vector2(0.0, 1.0))
	easing.add_point(Vector2(1.0, 1.0))
