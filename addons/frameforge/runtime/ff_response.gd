class_name FFResponse
extends Resource
## One collision response: where to go on a contact edge.
## A null response on a state means "inherit the sub-machine default".
##
## The target state is referenced BY NAME within the same sub-machine
## (see FFTransition for why: .tres cannot serialize cyclic object refs).

@export var target_state_name: StringName = &""
@export var target_behavior: FrameBehavior = null
## JSON round-trip: behavior name when target_behavior is set.
@export var target_behavior_name: String = ""
@export var min_incoming_speed: float = 0.0
## Contact must be clean for this many ticks before the edge can retrigger.
@export var rearm_ticks: int = 3

## Runtime cache, not serialized. Populated by BehaviorPlayer._rebuild().
var resolved_state: FrameState = null
