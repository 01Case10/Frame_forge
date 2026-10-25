//! G-6 built-in: ledgegrab (SM64-style).
//!
//! Grabs a ledge and holds it. Follows the stepkit decomp-verbatim
//! `act_ledge_grab` state diagram (grab → hold → climb / let-go), adapted to
//! the trait vocabulary. The climb-up itself stays data-driven — an authored
//! state with displacement curves; this logic only does the grab and hold.
//!
//! Per D9 the game does the spatial query: it sets `ledgegrab.available`
//! and the one-shot `ledgegrab.offset` (displacement from the player to the
//! grab pose). Params (all optional):
//! - `ledgegrab.offset`: `Vec3` snap-to-grab offset, consumed on enter.
//! - `ledgegrab.max_ticks`: hang budget, 0 = indefinite (default).
//!
//! Input actions read: `jump` (climb), `drop` (let go). Stick toward the
//! wall for 10 consecutive ticks auto-climbs; stick away lets go.

use crate::logic::{param_f32, take_vec3, LogicFactory, StateCtx, StateLogic};
use crate::vec3::ZERO;

/// Consecutive ticks of stick-toward-wall before auto-climb (SM64: 10).
const TOWARD_TICKS: u32 = 10;
/// Stick radius below which the stick counts as neutral.
const STICK_DEADZONE: f32 = 0.2;
/// Cosine threshold for toward/away classification (~60 deg cone).
const STICK_CONE_COS: f32 = 0.5;

pub struct LedgeGrab {
    toward_ticks: u32,
    elapsed: u32,
    max_ticks: u32,
}

impl LedgeGrab {
    pub fn new() -> Self {
        Self {
            toward_ticks: 0,
            elapsed: 0,
            max_ticks: 0,
        }
    }

    pub fn factory() -> LogicFactory {
        Box::new(|| Box::new(LedgeGrab::new()))
    }
}

impl Default for LedgeGrab {
    fn default() -> Self {
        Self::new()
    }
}

impl StateLogic for LedgeGrab {
    fn on_enter(&mut self, ctx: &mut StateCtx) {
        // One-shot snap to the grab pose; the game computed the offset.
        *ctx.delta = take_vec3(ctx.params, "ledgegrab.offset");
        // Face the wall (facing points into it).
        if ctx.contact.wall {
            let n = ctx.contact.wall_normal;
            *ctx.facing_yaw = (-n.x).atan2(-n.z).to_degrees();
        }
        self.toward_ticks = 0;
        self.elapsed = 0;
        self.max_ticks = param_f32(ctx.params, "ledgegrab.max_ticks", 0.0).max(0.0) as u32;
    }

    fn on_tick(&mut self, ctx: &mut StateCtx) {
        // Hold still — but not on the entry tick, where on_enter's snap is
        // the delta.
        if ctx.frame > 0 {
            *ctx.delta = ZERO;
        }

        // Wall lost → drop (SM64: steep floor / lost wall → let go).
        if !ctx.contact.wall {
            (ctx.fire)("ledgegrab_drop");
            return;
        }
        // Optional hang budget.
        if self.max_ticks > 0 {
            self.elapsed += 1;
            if self.elapsed >= self.max_ticks {
                (ctx.fire)("ledgegrab_drop");
                return;
            }
        }
        // Inputs: jump climbs (SM64 A → fast climb), drop lets go (SM64 Z).
        if ctx.input.just_pressed.contains("jump") {
            (ctx.fire)("ledgegrab_climb");
            return;
        }
        if ctx.input.just_pressed.contains("drop") {
            (ctx.fire)("ledgegrab_drop");
            return;
        }
        // Stick toward/away from the wall (SM64 timer-10 analog rule).
        // Wall normal points away from the wall, so toward-wall is negative.
        let r = (ctx.stick[0] * ctx.stick[0] + ctx.stick[1] * ctx.stick[1]).sqrt();
        if r >= STICK_DEADZONE {
            let d = ctx.stick_world.dot(ctx.contact.wall_normal);
            if d < -STICK_CONE_COS {
                self.toward_ticks += 1;
                if self.toward_ticks >= TOWARD_TICKS {
                    (ctx.fire)("ledgegrab_climb");
                    return;
                }
            } else {
                self.toward_ticks = 0;
            }
            if d > STICK_CONE_COS {
                (ctx.fire)("ledgegrab_drop");
            }
        } else {
            self.toward_ticks = 0;
        }
    }

    fn on_exit(&mut self, _ctx: &mut StateCtx) {}
}
