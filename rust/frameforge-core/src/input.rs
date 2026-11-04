//! Synthetic input replay with per-tick edge tracking.
//!
//! Mirrors the harness semantics: edges are tracked per 60 Hz tick from the
//! previous tick's state (NOT per render frame like
//! `Input.is_action_just_pressed`).

use std::collections::{HashMap, HashSet};

/// Pressed/held actions for one tick, with analog strengths.
#[derive(Debug, Clone, Default)]
pub struct TickInput {
    pub held: HashSet<String>,
    pub strengths: HashMap<String, f32>,
    /// Explicit edge signals for this tick. When non-empty, begin_tick()
    /// uses these directly instead of deriving from held deltas. This allows
    /// test harnesses to drive just_pressed deterministically.
    pub just_pressed: HashSet<String>,
}

/// Per-tick edge tracker fed by a recorded input script.
#[derive(Debug, Default)]
pub struct InputState {
    prev_held: HashSet<String>,
    pub held: HashSet<String>,
    pub just_pressed: HashSet<String>,
    pub just_released: HashSet<String>,
    pub strengths: HashMap<String, f32>,
    /// G-1: internal tick counter (incremented by begin_tick).
    tick: u64,
    /// G-1: last press tick per action, for buffered AnyPressed conditions.
    press_tick: HashMap<String, u64>,
}

impl InputState {
    /// Begin-tick: compute edges against last tick's held set.
    pub fn begin_tick(&mut self, tick: &TickInput) {
        self.tick = self.tick.wrapping_add(1);
        // Use explicit just_pressed when available.
        // On tick 1, never compute from delta (prev_held is empty, spurious).
        // After tick 1, if explicit set is non-empty use it; if empty, fall back
        // to delta for embedders that don't do edge detection (e.g. Godot).
        // diff.rs always populates just_pressed explicitly (empty = no press).
        if self.tick == 1 {
            self.just_pressed = tick.just_pressed.clone();
        } else if !tick.just_pressed.is_empty() {
            self.just_pressed = tick.just_pressed.clone();
        } else {
            // Backward compat: compute from delta for embedders without edge detection.
            // Note: diff.rs sets empty correctly, so this branch is for Godot/tests.
            // To avoid spurious presses, only compute if held is non-empty.
            // (If held is empty, just_pressed is definitely empty.)
            if tick.held.is_empty() {
                self.just_pressed = std::collections::HashSet::new();
            } else {
                self.just_pressed = tick.held.difference(&self.prev_held).cloned().collect();
            }
        }
        self.just_released = self.prev_held.difference(&tick.held).cloned().collect();
        self.held = tick.held.clone();
        self.strengths = tick.strengths.clone();
        // G-1: record the press tick for every newly pressed action.
        for a in &self.just_pressed {
            self.press_tick.insert(a.clone(), self.tick);
        }
    }

    /// End-tick: latch the held set for next tick's edges.
    /// (Mirrors `_end_tick`: `_input_prev` updates AFTER row evaluation.)
    pub fn end_tick(&mut self) {
        self.prev_held = self.held.clone();
    }

    /// G-1: true if `action` was pressed within the last `buffer` ticks,
    /// counting the press tick (buffer = 0 means "pressed this tick",
    /// identical to `just_pressed`).
    pub fn pressed_within(&self, action: &str, buffer: u32) -> bool {
        match self.press_tick.get(action) {
            Some(&p) => self.tick.saturating_sub(p) <= buffer as u64,
            None => false,
        }
    }

    /// G-1: consume a buffered press (called when a buffered OnInput row
    /// fires, so one press cannot trigger two transitions).
    pub fn consume_press(&mut self, action: &str) {
        self.press_tick.remove(action);
    }

    pub fn was_held(&self, a: &str) -> bool {
        self.prev_held.contains(a)
    }

    pub fn strength(&self, a: &str) -> f32 {
        self.strengths.get(a).copied().unwrap_or(0.0)
    }

    /// Godot `Input.get_axis(negative, positive)`.
    pub fn axis(&self, neg: &str, pos: &str) -> f32 {
        self.strength(pos) - self.strength(neg)
    }
}
