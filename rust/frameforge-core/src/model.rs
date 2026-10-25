//! FrameForge behavior data model.
//!
//! Serde-native port of the GDScript resources in
//! `addons/frameforge/runtime/` (`FrameState`, `SubStateMachine`,
//! `FrameBehavior`, `FFTransition`, `FFCondition`, `FFParameter`,
//! `FFResponse`, `FFStateEvent`, `FFComment`).
//!
//! Intra-behavior references are **by name** (`*_name` fields), matching the
//! GDScript name-based refs adopted after the Godot 4.6 cyclic-`.tres` bug.
//! The tick engine resolves them once per rebuild; this module only carries
//! the data.

use serde::{Deserialize, Serialize};

pub type Vec3 = [f32; 3];
pub type Vec2 = [f32; 2];

fn default_one() -> f32 {
    1.0
}

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DirectionSource {
    #[default]
    Author,
    ImpactNormal,
    Reflected,
    Input,
    Entry,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DisplacementSource {
    #[default]
    Author,
    Incoming,
    Entry,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InputPlane {
    #[default]
    Xz,
    Xy,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConditionType {
    #[default]
    OnComplete,
    OnInput,
    OnVariable,
    OnEvent,
    OnState,
    OnCustom,
    OnStick,
}

/// Reference direction for an OnStick angle check.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StickAngleVs {
    /// Angle between the stick and the track's facing yaw.
    #[default]
    Facing,
    /// Angle between the stick and the track's horizontal velocity.
    Velocity,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InputMode {
    #[default]
    AnyPressed,
    AnyReleased,
    AllReleased,
    AnyHeld,
    /// Pure level: none of the listed actions are currently held.
    NoneHeld,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Op {
    #[default]
    Eq,
    Ne,
    Gt,
    Ge,
    Lt,
    Le,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Momentum {
    #[default]
    Cut,
    Preserve,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ParamType {
    Bool,
    Int,
    #[default]
    Float,
    String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EventTrigger {
    #[default]
    OnEnter,
    OnExit,
    OnFrame,
}

/// Blackboard value. Untagged: JSON natives map directly.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum ParamValue {
    Bool(bool),
    Int(i64),
    Float(f64),
    Str(String),
    /// 3-component vector (e.g. spatial offsets for G-6 state logic).
    /// Untagged serde: serializes as a bare `[x, y, z]` array.
    Vec3([f32; 3]),
}

impl Default for ParamValue {
    fn default() -> Self {
        ParamValue::Float(0.0)
    }
}

// ---------------------------------------------------------------------------
// Easing curve (Godot Curve-compatible; sampling ported in easing.rs)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CurvePoint {
    pub pos: Vec2,
    #[serde(default)]
    pub left_tangent: f32,
    #[serde(default)]
    pub right_tangent: f32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EasingCurve {
    #[serde(default)]
    pub points: Vec<CurvePoint>,
    #[serde(default)]
    pub min_value: f32,
    #[serde(default = "default_one")]
    pub max_value: f32,
}

impl Default for EasingCurve {
    /// Flat 1.0 — the GDScript `_init` default (even distribution).
    fn default() -> Self {
        Self {
            points: vec![
                CurvePoint {
                    pos: [0.0, 1.0],
                    left_tangent: 0.0,
                    right_tangent: 0.0,
                },
                CurvePoint {
                    pos: [1.0, 1.0],
                    left_tangent: 0.0,
                    right_tangent: 0.0,
                },
            ],
            min_value: 0.0,
            max_value: 1.0,
        }
    }
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResponseRef {
    #[serde(default)]
    pub target_state_name: String,
    /// Empty = no behavior switch.
    #[serde(default)]
    pub target_behavior_name: String,
    #[serde(default)]
    pub min_incoming_speed: f32,
    #[serde(default = "default_rearm")]
    pub rearm_ticks: u32,
}

fn default_rearm() -> u32 {
    3
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StateEvent {
    #[serde(default)]
    pub event_name: String,
    #[serde(default)]
    pub trigger: EventTrigger,
    #[serde(default)]
    pub frame: u32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FrameState {
    #[serde(default = "default_state_name")]
    pub state_name: String,
    #[serde(default)]
    pub displacement: f32,
    #[serde(default)]
    pub direction: Vec3,
    #[serde(default = "default_one_frame")]
    pub duration_frames: u32,
    #[serde(default)]
    pub easing: EasingCurve,
    #[serde(default)]
    pub direction_source: DirectionSource,
    #[serde(default)]
    pub displacement_source: DisplacementSource,
    #[serde(default = "default_one")]
    pub restitution: f32,
    // INPUT direction config
    #[serde(default)]
    pub input_left: String,
    #[serde(default)]
    pub input_right: String,
    #[serde(default)]
    pub input_forward: String,
    #[serde(default)]
    pub input_back: String,
    #[serde(default)]
    pub input_plane: InputPlane,
    #[serde(default = "default_deadzone")]
    pub input_deadzone: f32,
    #[serde(default)]
    pub camera_relative: bool,
    /// Max direction change per tick in degrees (0 = instant).
    #[serde(default)]
    pub input_turn_rate_deg: f32,
    // Collision responses; None = inherit sub-machine default.
    #[serde(default)]
    pub resp_floor: Option<ResponseRef>,
    #[serde(default)]
    pub resp_ceiling: Option<ResponseRef>,
    #[serde(default)]
    pub resp_wall: Option<ResponseRef>,
    #[serde(default)]
    pub events: Vec<StateEvent>,
    #[serde(default)]
    pub transitions: Vec<Transition>,
    /// G-4: blackboard writes applied when this state is entered (after the
    /// state switch, before OnEnter events are queued).
    #[serde(default)]
    pub enter_params: Vec<ParamAssign>,
    /// G-5: per-tick steering. When present, the state's delta is integrated
    /// from a persistent per-track velocity instead of authored
    /// displacement x easing. See SteerConfig.
    #[serde(default)]
    pub steer: Option<SteerConfig>,
    /// G-6: name of a registered `StateLogic` implementation that drives
    /// this state (e.g. "wallrun"). None = pure data state.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub logic: Option<String>,
    /// Editor-only canvas position; round-tripped, zero runtime effect.
    #[serde(default)]
    pub editor_position: Vec2,
}

fn default_state_name() -> String {
    "State".to_string()
}
fn default_one_frame() -> u32 {
    1
}
fn default_deadzone() -> f32 {
    0.2
}

// ---------------------------------------------------------------------------
// G-5: per-tick steering
// ---------------------------------------------------------------------------

/// How a steered state orients the track's facing yaw each tick.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FaceMode {
    /// Facing never changes.
    #[default]
    Keep,
    /// Facing snaps to the horizontal velocity angle whenever moving.
    Velocity,
    /// Facing turns toward the stick direction using `TurnModel`
    /// (plus the optional quickturn override).
    Stick,
}

/// One speed tier of the turn-rate cap: applies while horizontal speed is at
/// most `speed_max`. Raw cap = `cap_base + cap_per_speed * speed +
/// cap_per_radius * stick_radius`, then clamped to [`cap_min`, `cap_max`]
/// (a bound of 0 disables that side). The first matching tier wins; make the
/// last tier's `speed_max` huge as a fallback. An empty tier list means
/// "no speed-based cap".
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TurnTier {
    pub speed_max: f32,
    pub cap_base: f32,
    #[serde(default)]
    pub cap_per_speed: f32,
    #[serde(default)]
    pub cap_per_radius: f32,
    #[serde(default)]
    pub cap_min: f32,
    #[serde(default)]
    pub cap_max: f32,
}

/// Turn-rate model toward the stick (degrees / degrees per tick).
/// Mirrors the documented tiered turn rules: no turn within `deadzone_deg`,
/// angular acceleration `accel_near_frac` x cap while the facing error is in
/// (`deadzone_deg`, `far_angle_deg`], `accel_far_frac` x cap in
/// (`far_angle_deg`, `max_angle_deg`], no turn beyond `max_angle_deg`.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct TurnModel {
    #[serde(default)]
    pub deadzone_deg: f32,
    #[serde(default)]
    pub tiers: Vec<TurnTier>,
    #[serde(default)]
    pub accel_near_frac: f32,
    #[serde(default)]
    pub accel_far_frac: f32,
    #[serde(default)]
    pub far_angle_deg: f32,
    #[serde(default)]
    pub max_angle_deg: f32,
}

/// Initial vertical velocity when a steered state is entered.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EnterVy {
    /// Keep the track's current vertical velocity.
    #[default]
    Keep,
    /// Set vertical velocity to the value (e.g. a jump's initial speed).
    Set(f32),
    /// Add to the current vertical velocity.
    Add(f32),
}

/// Per-tick steering for one state (G-5). All rates are per 60 Hz tick;
/// speeds in units per tick; angles in degrees. Every field defaults to
/// "off", so a `SteerConfig` only does what it is configured to do.
///
/// Update order per tick: horizontal accel (below cap) or decel (above cap)
/// -> multiplicative decay -> hard max clamp -> gravity + terminal velocity
/// -> facing update. The tick's delta is the resulting velocity.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SteerConfig {
    /// Forward accel per unit of forward stick (facing frame), u/tick^2.
    #[serde(default)]
    pub accel_forward: f32,
    /// Sideways accel per unit of sideways stick (signed), u/tick^2.
    #[serde(default)]
    pub accel_side: f32,
    /// Backward accel per unit of back stick, u/tick^2.
    #[serde(default)]
    pub accel_backward: f32,
    /// When true, backward accel only applies while forward speed > 0, and
    /// never pushes forward speed below 0.
    #[serde(default)]
    pub backward_until_zero: bool,
    /// Accel along the current horizontal velocity direction, per unit of
    /// stick radius, u/tick^2.
    #[serde(default)]
    pub accel_along_velocity: f32,
    /// Horizontal speed cap: `speed_cap + speed_cap_per_radius * radius`.
    /// Accel is skipped at/above the cap. 0/0 = no cap.
    #[serde(default)]
    pub speed_cap: f32,
    #[serde(default)]
    pub speed_cap_per_radius: f32,
    /// Minimum horizontal speed; enforced per tick by scaling up (0 = none).
    #[serde(default)]
    pub speed_min: f32,
    /// On entry, set horizontal velocity to the last impact normal's XZ *
    /// this speed (0 = disabled). For wall jumps: launch away from the wall.
    #[serde(default)]
    pub enter_impact_speed: f32,
    /// Linear decel toward the cap when above it, u/tick^2. 0 = none.
    #[serde(default)]
    pub decel_above_cap: f32,
    /// Hard clamp on horizontal speed. 0 = none.
    #[serde(default)]
    pub max_speed: f32,
    /// Fractional horizontal-speed decay per tick (0.002 = 0.2%). 0 = none.
    #[serde(default)]
    pub decay: f32,
    /// Downward accel per tick, u/tick^2. 0 = none.
    #[serde(default)]
    pub gravity: f32,
    /// Max fall-speed magnitude; vy is clamped to >= -terminal_velocity.
    /// 0 = none.
    #[serde(default)]
    pub terminal_velocity: f32,
    #[serde(default)]
    pub face_mode: FaceMode,
    #[serde(default)]
    pub turn: TurnModel,
    /// When the stick is at least this far from facing, the turn cap for the
    /// tick becomes `quickturn_rate_deg` (and the rate is applied directly
    /// rather than ramped). 0 = off.
    #[serde(default)]
    pub quickturn_angle_deg: f32,
    #[serde(default)]
    pub quickturn_rate_deg: f32,
    /// On entry, seed horizontal velocity from the incoming motion
    /// (last tick's delta). When false, horizontal velocity starts at 0.
    #[serde(default = "default_true")]
    pub enter_keep_horizontal: bool,
    /// On entry, how to set vertical velocity.
    #[serde(default)]
    pub enter_vy: EnterVy,
}

fn default_true() -> bool {
    true
}

impl Default for SteerConfig {
    fn default() -> Self {
        Self {
            accel_forward: 0.0,
            accel_side: 0.0,
            accel_backward: 0.0,
            backward_until_zero: false,
            accel_along_velocity: 0.0,
            speed_cap: 0.0,
            speed_cap_per_radius: 0.0,
            speed_min: 0.0,
            enter_impact_speed: 0.0,
            decel_above_cap: 0.0,
            max_speed: 0.0,
            decay: 0.0,
            gravity: 0.0,
            terminal_velocity: 0.0,
            face_mode: FaceMode::Keep,
            turn: TurnModel::default(),
            quickturn_angle_deg: 0.0,
            quickturn_rate_deg: 0.0,
            enter_keep_horizontal: true,
            enter_vy: EnterVy::Keep,
        }
    }
}

// ---------------------------------------------------------------------------
// G-4: spin-gesture detector configuration
// ---------------------------------------------------------------------------

fn default_spin_min() -> u32 {
    31
}
fn default_spin_max() -> u32 {
    70
}
fn default_spin_tol() -> f32 {
    45.57
}
fn default_spin_area() -> f32 {
    5.0
}
fn default_spin_buffer() -> u32 {
    30
}
fn default_spin_param() -> String {
    "spin.valid".to_string()
}

/// Optional behavior-level stick-gesture detector (G-4). Watches the
/// embedder-supplied stick for a sustained rotation and publishes the result
/// as a boolean blackboard parameter (default `spin.valid`), buffered for
/// `buffer_ticks` after the gesture completes.
///
/// Rule transcribed from the guard vocabulary: 31-70 consecutive rotating
/// frames, first/last stick angles within ~45.57 deg, swept sector area at
/// least 5 square units, then a 30-tick window to use it. Any non-zero radius
/// counts as non-neutral for the detector (unlike the 0.1 neutral zone).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SpinDetectConfig {
    #[serde(default = "default_spin_min")]
    pub min_frames: u32,
    #[serde(default = "default_spin_max")]
    pub max_frames: u32,
    #[serde(default = "default_spin_tol")]
    pub angle_tolerance_deg: f32,
    #[serde(default = "default_spin_area")]
    pub min_area: f32,
    #[serde(default = "default_spin_buffer")]
    pub buffer_ticks: u32,
    #[serde(default = "default_spin_param")]
    pub output_param: String,
}

impl Default for SpinDetectConfig {
    fn default() -> Self {
        Self {
            min_frames: default_spin_min(),
            max_frames: default_spin_max(),
            angle_tolerance_deg: default_spin_tol(),
            min_area: default_spin_area(),
            buffer_ticks: default_spin_buffer(),
            output_param: default_spin_param(),
        }
    }
}

// ---------------------------------------------------------------------------
// Transition + condition
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Transition {
    #[serde(default)]
    pub condition: Condition,
    #[serde(default)]
    pub target_state_name: String,
    /// Empty = no behavior switch.
    #[serde(default)]
    pub target_behavior_name: String,
    #[serde(default)]
    pub momentum: Momentum,
    #[serde(default = "default_blend")]
    pub blend_frames: u32,
    #[serde(default)]
    pub fire_event: String,
    #[serde(default)]
    pub silent: bool,
    /// G-4: blackboard writes applied when this row fires (before the state
    /// switch). Used for flag rules: set/clear flags, arm countdowns.
    #[serde(default)]
    pub on_fire_params: Vec<ParamAssign>,
    /// Provenance: spec transition id + source tag, e.g. "GR-06 [W-rule]".
    /// Kept through resolve; used by fidelity lints.
    #[serde(default)]
    pub source_tag: String,
}

fn default_blend() -> u32 {
    3
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct Condition {
    #[serde(rename = "type", default)]
    pub cond_type: ConditionType,
    #[serde(default)]
    pub input_actions: Vec<String>,
    #[serde(default)]
    pub input_mode: InputMode,
    /// G-1: for AnyPressed, how many ticks after the press tick the press
    /// stays valid (0 = this tick only, i.e. the legacy just_pressed).
    /// A press consumed by a firing row is cleared (see tick.rs).
    #[serde(default)]
    pub buffer_ticks: u32,
    #[serde(default)]
    pub param_name: String,
    #[serde(default)]
    pub param_op: Op,
    #[serde(default)]
    pub param_value: ParamValue,
    #[serde(default)]
    pub event_name: String,
    #[serde(default)]
    pub target_machine_name: String,
    #[serde(default)]
    pub target_state_name: String,
    #[serde(default)]
    pub custom_name: String,
    // ---- G-2: OnStick fields ----
    /// Minimum stick radius (0..1). Default 0.
    #[serde(default)]
    pub stick_radius_min: f32,
    /// Maximum stick radius. Default +inf (no upper bound).
    #[serde(default = "f32_max")]
    pub stick_radius_max: f32,
    #[serde(default)]
    pub stick_angle_vs: StickAngleVs,
    /// Minimum unsigned angle (degrees) between stick and reference.
    #[serde(default)]
    pub stick_angle_min_deg: f32,
    /// Maximum unsigned angle (degrees) between stick and reference.
    #[serde(default = "deg_180")]
    pub stick_angle_max_deg: f32,
    // ---- Composite conditions (Phase C) ----
    /// All of these must be true. When non-empty, the composite defines the
    /// condition and `cond_type` is ignored.
    #[serde(default)]
    pub all_of: Vec<Condition>,
    /// At least one of these must be true. When non-empty (and `all_of` is
    /// empty), the composite defines the condition.
    #[serde(default)]
    pub any_of: Vec<Condition>,
}

fn f32_max() -> f32 {
    f32::MAX
}

fn deg_180() -> f32 {
    180.0
}

/// Reserved blackboard name (G-3): reads the current track's frame index.
/// Never set by the embedder; the engine resolves it during OnVariable
/// evaluation.
pub const STATE_STEP_PARAM: &str = "state_step";

/// A blackboard write applied when a transition fires (G-4) or when a state
/// is entered (FrameState::enter_params).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum ParamAssign {
    /// Set the parameter to a value immediately.
    Set { name: String, value: ParamValue },
    /// Set the parameter to `ticks` (as an integer) and decrement it once
    /// per tick until it reaches 0. Used for timed flags: input locks,
    /// quickturn latches, cap-return windows, spin buffers.
    Countdown { name: String, ticks: u32 },
}

// ---------------------------------------------------------------------------
// Machine / behavior
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Comment {
    #[serde(default = "default_comment_title")]
    pub title: String,
    #[serde(default)]
    pub position: Vec2,
    #[serde(default = "default_comment_size")]
    pub size: Vec2,
    #[serde(default = "default_comment_tint")]
    pub tint: [f32; 4],
}

fn default_comment_title() -> String {
    "Comment".to_string()
}
fn default_comment_size() -> Vec2 {
    [280.0, 160.0]
}
fn default_comment_tint() -> [f32; 4] {
    [0.9, 0.8, 0.4, 1.0]
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SubStateMachine {
    #[serde(default = "default_machine_name")]
    pub machine_name: String,
    #[serde(default)]
    pub states: Vec<FrameState>,
    #[serde(default)]
    pub entry_state_name: String,
    #[serde(default)]
    pub default_resp_floor: Option<ResponseRef>,
    #[serde(default)]
    pub default_resp_ceiling: Option<ResponseRef>,
    #[serde(default)]
    pub default_resp_wall: Option<ResponseRef>,
    #[serde(default)]
    pub editor_comments: Vec<Comment>,
}

fn default_machine_name() -> String {
    "Machine".to_string()
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Parameter {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub ptype: ParamType,
    #[serde(default)]
    pub default_value: ParamValue,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FrameBehavior {
    #[serde(default = "default_behavior_name")]
    pub behavior_name: String,
    #[serde(default)]
    pub sub_machines: Vec<SubStateMachine>,
    #[serde(default)]
    pub parameters: Vec<Parameter>,
    #[serde(default)]
    pub behavior_transitions: Vec<Transition>,
    #[serde(default)]
    pub on_enter_event: String,
    #[serde(default)]
    pub on_exit_event: String,
    /// G-4: optional stick spin-gesture detector for the whole behavior.
    #[serde(default)]
    pub spin_detect: Option<SpinDetectConfig>,
}

fn default_behavior_name() -> String {
    "Behavior".to_string()
}

impl FrameBehavior {
    /// Load from a JSON file (the canonical behavior format).
    pub fn load_json(path: &str) -> Result<Self, String> {
        let text = std::fs::read_to_string(path).map_err(|e| e.to_string())?;
        Self::load_json_str(&text).map_err(|e| format!("{}: {}", path, e))
    }

    /// Parse from a JSON string.
    pub fn load_json_str(text: &str) -> Result<Self, String> {
        serde_json::from_str(text).map_err(|e| e.to_string())
    }

    /// Resolve a state name within a machine (rebuild-time name resolution).
    pub fn find_state<'a>(machine: &'a SubStateMachine, name: &str) -> Option<&'a FrameState> {
        machine.states.iter().find(|s| s.state_name == name)
    }
}

// ---------------------------------------------------------------------------
// Defaults matching the GDScript @export initializers.

impl Default for FrameState {
    fn default() -> Self {
        Self {
            state_name: "State".to_string(),
            displacement: 0.0,
            direction: [0.0, 0.0, 0.0],
            duration_frames: 1,
            easing: EasingCurve::default(),
            direction_source: DirectionSource::Author,
            displacement_source: DisplacementSource::Author,
            restitution: 1.0,
            input_left: String::new(),
            input_right: String::new(),
            input_forward: String::new(),
            input_back: String::new(),
            input_plane: InputPlane::Xz,
            input_deadzone: 0.2,
            camera_relative: false,
            input_turn_rate_deg: 0.0,
            resp_floor: None,
            resp_ceiling: None,
            resp_wall: None,
            events: Vec::new(),
            transitions: Vec::new(),
            enter_params: Vec::new(),
            steer: None,
            logic: None,
            editor_position: [0.0, 0.0],
        }
    }
}

impl Default for Transition {
    fn default() -> Self {
        Self {
            condition: Condition::default(),
            target_state_name: String::new(),
            target_behavior_name: String::new(),
            momentum: Momentum::Cut,
            blend_frames: 3,
            fire_event: String::new(),
            silent: false,
            on_fire_params: Vec::new(),
            source_tag: String::new(),
        }
    }
}

impl Default for SubStateMachine {
    fn default() -> Self {
        Self {
            machine_name: "Machine".to_string(),
            states: Vec::new(),
            entry_state_name: String::new(),
            default_resp_floor: None,
            default_resp_ceiling: None,
            default_resp_wall: None,
            editor_comments: Vec::new(),
        }
    }
}

impl Default for FrameBehavior {
    fn default() -> Self {
        Self {
            behavior_name: "Behavior".to_string(),
            sub_machines: Vec::new(),
            parameters: Vec::new(),
            behavior_transitions: Vec::new(),
            on_enter_event: String::new(),
            on_exit_event: String::new(),
            spin_detect: None,
        }
    }
}

impl Default for ResponseRef {
    fn default() -> Self {
        Self {
            target_state_name: String::new(),
            target_behavior_name: String::new(),
            min_incoming_speed: 0.0,
            rearm_ticks: 3,
        }
    }
}

impl Default for Comment {
    fn default() -> Self {
        Self {
            title: "Comment".to_string(),
            position: [0.0, 0.0],
            size: [280.0, 160.0],
            tint: [0.9, 0.8, 0.4, 1.0],
        }
    }
}

impl Default for Parameter {
    fn default() -> Self {
        Self {
            name: String::new(),
            ptype: ParamType::Float,
            default_value: ParamValue::Float(0.0),
        }
    }
}

impl Default for StateEvent {
    fn default() -> Self {
        Self {
            event_name: String::new(),
            trigger: EventTrigger::OnEnter,
            frame: 0,
        }
    }
}

impl Default for CurvePoint {
    fn default() -> Self {
        Self {
            pos: [0.0, 0.0],
            left_tangent: 0.0,
            right_tangent: 0.0,
        }
    }
}
