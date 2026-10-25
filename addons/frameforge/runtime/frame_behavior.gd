class_name FrameBehavior
extends Resource
## The super state machine: a named set of SubStateMachines running in parallel.

@export var behavior_name: String = "Behavior"
@export var sub_machines: Array[SubStateMachine] = []
@export var parameters: Array[FFParameter] = []
@export var behavior_transitions: Array[FFTransition] = []
@export var on_enter_event: String = ""
@export var on_exit_event: String = ""
## Spin-gesture detection (Rust `spin_detect`); null = disabled.
@export var spin_detect: FFSpinDetect = null
