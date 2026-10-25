class_name FFSpinDetect
extends Resource
## Spin-gesture detector config (Rust `SpinDetectConfig`): watches the
## stick trace for a full rotation inside a frame window and sets
## `output_param` true for `buffer_ticks` ticks. Defaults mirror the
## core's serde defaults.

@export var min_frames: int = 31
@export var max_frames: int = 70
@export var angle_tolerance_deg: float = 45.57
@export var min_area: float = 5.0
@export var buffer_ticks: int = 30
@export var output_param: String = "spin.valid"
