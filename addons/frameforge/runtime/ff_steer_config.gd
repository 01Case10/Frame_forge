class_name FFSteerConfig
extends Resource
## G-5 steering config (mirrors Rust `SteerConfig` field-for-field).
##
## When a FrameState has a steer config, its per-tick delta is integrated
## from a persistent velocity instead of authored displacement x easing.

enum FaceMode { KEEP, VELOCITY, STICK }
enum EnterVy { KEEP, SET, ADD }

@export var accel_forward: float = 0.0
@export var accel_side: float = 0.0
@export var accel_backward: float = 0.0
@export var backward_until_zero: bool = false
@export var accel_along_velocity: float = 0.0
@export var speed_cap: float = 0.0
@export var speed_cap_per_radius: float = 0.0
@export var speed_min: float = 0.0
@export var enter_impact_speed: float = 0.0
@export var decel_above_cap: float = 0.0
@export var max_speed: float = 0.0
@export var decay: float = 0.0
@export var gravity: float = 0.0
@export var terminal_velocity: float = 0.0
@export var face_mode: int = FaceMode.KEEP
## How to seed vertical velocity on entry.
@export var enter_vy: int = EnterVy.KEEP
## Used when enter_vy == SET or ADD.
@export var enter_vy_value: float = 0.0
@export var quickturn_angle_deg: float = 0.0
@export var quickturn_rate_deg: float = 0.0
@export var enter_keep_horizontal: bool = true
# Nested turn model (Rust `TurnModel`), flattened with a turn_ prefix.
@export var turn_deadzone_deg: float = 0.0
@export var turn_accel_near_frac: float = 0.0
@export var turn_accel_far_frac: float = 0.0
@export var turn_far_angle_deg: float = 0.0
@export var turn_max_angle_deg: float = 0.0
@export var turn_tiers: Array[FFTurnTier] = []
