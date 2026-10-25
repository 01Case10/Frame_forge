class_name SubStateMachine
extends Resource
## A sequential chain of FrameStates; exactly one state is active at a time.
## Several sub-machines run in parallel inside a FrameBehavior.

@export var machine_name: String = "Machine"
@export var states: Array[FrameState] = []
@export var entry_state: FrameState = null
# Default collision responses inherited by states with null resp_*.
@export var default_resp_floor: FFResponse = null
@export var default_resp_ceiling: FFResponse = null
@export var default_resp_wall: FFResponse = null
## Editor-only: comment frames on the graph canvas.
@export var editor_comments: Array[FFComment] = []
