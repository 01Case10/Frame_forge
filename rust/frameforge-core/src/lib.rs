//! `frameforge-core`: FrameForge behavior data model and 60 Hz tick engine.
//!
//! Pure Rust — no Godot dependency. The engine here must reproduce the
//! GDScript `BehaviorPlayer` bit-for-bit; the Phase 3 parity gate (14/14
//! exit-gate differentials + 58/58 headless checks) enforces it.

pub mod easing;
pub mod gesture;
pub mod input;
pub mod logic;
pub mod logics;
pub mod model;
pub mod tick;
pub mod validate;
pub mod vec3;

pub use model::*;
