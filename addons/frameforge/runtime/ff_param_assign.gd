class_name FFParamAssign
extends Resource
## One blackboard parameter assignment (G-4).
##
## Used for state `enter_params` and transition `on_fire_params`.
## Mirrors the Rust `ParamAssign` enum (serde tag "op").

enum Kind { SET, COUNTDOWN }

## SET: write `value` now. COUNTDOWN: write `ticks` as an int, decremented
## once per tick until it reaches 0.
@export var kind: int = Kind.SET
@export var name: String = ""
## Used when kind == SET. Maps to Rust `ParamValue`: bool/int/float/String
## pass through; Vector3 serializes as a [x, y, z] array.
@export var value: Variant = 0.0
## Used when kind == COUNTDOWN.
@export var ticks: int = 0
