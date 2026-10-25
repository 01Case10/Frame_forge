//! G-6 built-in: poleclimb.
//!
//! Grabs a pole, climbs it with the stick, and dismounts. Designed from
//! SM64's known pole behavior (grab → climb up/down → jump off or mount the
//! top); stepkit deferred poles, so this is original, not ported.
//!
//! Per D9 the game does the spatial queries: it sets `poleclimb.available`,
//! the one-shot `poleclimb.snap` (offset to the grab pose), refreshes
//! `poleclimb.recenter` every tick (horizontal offset from the player back
//! to the pole axis), and sets `poleclimb.top` at the pole top. Params:
//! - `poleclimb.speed`: climb speed, units/tick (default 0.05).
//!
//! Input actions read: `jump` (leap off), `drop` (let go). Stick y drives
//! the climb.

use crate::logic::{param_bool, param_f32, param_vec3, take_vec3, LogicFactory, StateCtx, StateLogic};
use crate::vec3::{Vec3, ZERO};

const DEFAULT_SPEED: f32 = 0.05;

pub struct PoleClimb;

impl PoleClimb {
    pub fn new() -> Self {
        Self
    }

    pub fn factory() -> LogicFactory {
        Box::new(|| Box::new(PoleClimb::new()))
    }
}

impl Default for PoleClimb {
    fn default() -> Self {
        Self::new()
    }
}

impl StateLogic for PoleClimb {
    fn on_enter(&mut self, ctx: &mut StateCtx) {
        // One-shot snap to the grab pose; the game computed the offset.
        *ctx.delta = take_vec3(ctx.params, "poleclimb.snap");
        // Face the pole (recenter points from the player to the axis).
        if let Some(r) = param_vec3(ctx.params, "poleclimb.recenter") {
            if r.length() > 1e-4 {
                *ctx.facing_yaw = r.x.atan2(r.z).to_degrees();
            }
        }
    }

    fn on_tick(&mut self, ctx: &mut StateCtx) {
        // Pole lost (game's call) → drop.
        if !param_bool(ctx.params, "poleclimb.available", true) {
            *ctx.delta = ZERO;
            (ctx.fire)("poleclimb_drop");
            return;
        }
        // Glue to the pole axis (game refreshes `recenter` every tick) and
        // climb with vertical stick — but not on the entry tick, where
        // on_enter's snap is the delta.
        let sy = ctx.stick[1].clamp(-1.0, 1.0);
        if ctx.frame > 0 {
            let speed = param_f32(ctx.params, "poleclimb.speed", DEFAULT_SPEED);
            let recenter = param_vec3(ctx.params, "poleclimb.recenter").unwrap_or(ZERO);
            *ctx.delta = Vec3::new(recenter.x, sy * speed, recenter.z);
        }

        if ctx.input.just_pressed.contains("jump") {
            *ctx.delta = ZERO;
            (ctx.fire)("poleclimb_jump");
            return;
        }
        if ctx.input.just_pressed.contains("drop") {
            *ctx.delta = ZERO;
            (ctx.fire)("poleclimb_drop");
            return;
        }
        if param_bool(ctx.params, "poleclimb.top", false) && sy > 0.5 {
            *ctx.delta = ZERO;
            (ctx.fire)("poleclimb_top");
        }
    }

    fn on_exit(&mut self, _ctx: &mut StateCtx) {}
}
