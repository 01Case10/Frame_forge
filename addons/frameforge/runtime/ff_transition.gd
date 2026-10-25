class_name FFTransition
extends Resource
## One ordered transition row on a FrameState.
##
## The target state is referenced BY NAME within the same sub-machine
## (like Godot's AnimationNodeStateMachine): object references would make
## the resource graph cyclic, which Godot's .tres saver corrupts
## (back-edges are silently written as null). BehaviorPlayer resolves
## names to objects once per rebuild into `resolved_state` below.

enum Momentum { CUT, PRESERVE }

@export var condition: FFCondition = null
@export var target_state_name: StringName = &""
@export var target_behavior: FrameBehavior = null
## JSON round-trip: behavior name when target_behavior is set.
@export var target_behavior_name: String = ""
@export var momentum: int = Momentum.CUT
@export var blend_frames: int = 3
@export var fire_event: String = ""
@export var silent: bool = false
## G-4: blackboard params applied when this row fires.
@export var on_fire_params: Array[FFParamAssign] = []
## Provenance tag from transcription/authoring (e.g. "GR-05 [pri 40]").
## Preserved so editor JSON round-trips don't strip it.
@export var source_tag: String = ""

## Runtime cache, not serialized. Populated by BehaviorPlayer._rebuild().
var resolved_state: FrameState = null
