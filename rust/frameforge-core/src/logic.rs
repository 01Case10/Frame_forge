//! G-6: trait-based custom state logic.
//!
//! A state with `logic: Some(name)` in the behavior JSON runs a Rust
//! [`StateLogic`] implementation looked up in the runtime registry. This is
//! how complex states (wallrun, ledgegrab, poleclimb) keep per-tick memory
//! without giving up the core's determinism.
//!
//! # Determinism contract
//!
//! Implementations must be pure functions of the [`StateCtx`] they are
//! given: no I/O, no clocks, no RNG (use a seeded generator if you must),
//! no Godot access. Everything a logic needs from the world arrives as data
//! through the context (params, contact state). A logic that breaks this
//! contract breaks headless testing and the exit-gate differentials.
//!
//! # Spatial facts (D9)
//!
//! The core is position-agnostic: it emits deltas, the game holds position.
//! A logic can therefore never answer "where is the ledge?". Spatial facts
//! (offsets, availability flags) arrive as params written by the game,
//! which does the raycasts. `Vec3` params use [`ParamValue::Vec3`].

use crate::input::InputState;
use crate::model::ParamValue;
use crate::tick::ContactState;
use crate::vec3::Vec3;
use std::collections::HashMap;

/// Names of the built-in logics, pre-registered by `Runtime::new`.
/// `validate.rs` and the editor mirror this list.
pub const BUILTIN_LOGIC_NAMES: &[&str] = &["wallrun", "ledgegrab", "poleclimb"];

/// Capability window handed to [`StateLogic`] implementations. This is the
/// only part of the engine a logic can touch.
pub struct StateCtx<'a> {
    /// Edge-tracked input for this tick (held / just_pressed / ...).
    pub input: &'a InputState,
    /// Embedder-set stick vector: x right, y up/forward, length clamped.
    pub stick: [f32; 2],
    /// Stick direction in world space (camera-relative), horizontal,
    /// normalized. Zero when the stick is neutral.
    pub stick_world: Vec3,
    /// The behavior blackboard. Logics read tuning + game-supplied spatial
    /// facts here and may write params (e.g. consume a one-shot offset).
    pub params: &'a mut HashMap<String, ParamValue>,
    /// Last tick's contact state (D3: 1 tick stale — fine for walls).
    pub contact: &'a ContactState,
    /// Current frame of the active state (0 = just entered).
    pub frame: u32,
    /// Track facing yaw in degrees. Logics may reface (e.g. face the wall).
    pub facing_yaw: &'a mut f32,
    /// This tick's delta. Starts as the authored/steered delta; the logic
    /// may overwrite it entirely.
    pub delta: &'a mut Vec3,
    /// Fire a named event with `push_event` semantics: visible to engine
    /// `OnEvent` conditions at tick N+1, to the game as `event_fired` at
    /// end of tick N (D6). Transitions themselves stay authored (D4).
    pub fire: &'a mut dyn FnMut(&str),
}

/// Custom per-state behavior. One instance per track entry, created by the
/// [`LogicFactory`] when the state is entered and dropped on exit.
pub trait StateLogic {
    /// Called once when the state is entered, after `enter_params` are
    /// applied and before the enter signal is logged. Skipped on silent
    /// self-transitions. May set `*ctx.delta`: it becomes the entry tick's
    /// base delta (`on_tick` runs after and may overwrite it).
    fn on_enter(&mut self, ctx: &mut StateCtx);
    /// Called every tick while the state is active, after row evaluation
    /// and before Preserve blending. May rewrite `*ctx.delta`.
    fn on_tick(&mut self, ctx: &mut StateCtx);
    /// Called once when the state is exited, alongside the old state's
    /// OnExit handling. Skipped on silent self-transitions.
    fn on_exit(&mut self, ctx: &mut StateCtx);
}

/// Builds a fresh [`StateLogic`] instance per track entry.
pub type LogicFactory = Box<dyn Fn() -> Box<dyn StateLogic>>;

// ---------------------------------------------------------------------------
// Param helpers for logic implementations.
// ---------------------------------------------------------------------------

/// Read a numeric param (Float or Int; Bool counts as 1.0/0.0 like the
/// engine's `as_f64`), else `default`.
pub fn param_f32(params: &HashMap<String, ParamValue>, name: &str, default: f32) -> f32 {
    match params.get(name) {
        Some(ParamValue::Float(f)) => *f as f32,
        Some(ParamValue::Int(i)) => *i as f32,
        Some(ParamValue::Bool(b)) => {
            if *b {
                1.0
            } else {
                0.0
            }
        }
        _ => default,
    }
}

/// Read a bool param, else `default`.
pub fn param_bool(params: &HashMap<String, ParamValue>, name: &str, default: bool) -> bool {
    match params.get(name) {
        Some(ParamValue::Bool(b)) => *b,
        _ => default,
    }
}

/// Read a `Vec3` param, else `None`.
pub fn param_vec3(params: &HashMap<String, ParamValue>, name: &str) -> Option<Vec3> {
    match params.get(name) {
        Some(ParamValue::Vec3([x, y, z])) => Some(Vec3::new(*x, *y, *z)),
        _ => None,
    }
}

/// Write a `Vec3` param.
pub fn set_vec3(params: &mut HashMap<String, ParamValue>, name: &str, v: Vec3) {
    params.insert(name.to_string(), ParamValue::Vec3([v.x, v.y, v.z]));
}

/// Read a `Vec3` param and zero it (one-shot spatial offsets, D9).
pub fn take_vec3(params: &mut HashMap<String, ParamValue>, name: &str) -> Vec3 {
    let v = param_vec3(params, name).unwrap_or(Vec3::new(0.0, 0.0, 0.0));
    set_vec3(params, name, Vec3::new(0.0, 0.0, 0.0));
    v
}

/// Write a bool param.
pub fn set_bool(params: &mut HashMap<String, ParamValue>, name: &str, v: bool) {
    params.insert(name.to_string(), ParamValue::Bool(v));
}
