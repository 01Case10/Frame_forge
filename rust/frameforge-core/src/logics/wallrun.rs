//! G-6 built-in: wallrun.
//!
//! Runs along a wall, remembering its normal across ticks. Exits (via the
//! `wallrun_end` event — transitions stay authored, D4) when the wall is
//! lost, the normal swings, or the tick budget expires.
//!
//! Params (all optional):
//! - `wallrun_speed`: along-wall speed, units/tick (default 0.15).
//! - `wallrun_max_ticks`: run budget in ticks (default 45).
//! - `wallrun.available`: set false by the game when the touched wall is
//!   tagged non-runnable (default true). The game owns the tag (e.g. a
//!   `no_wallrun` group on the StaticBody3D) and maps it to this param
//!   each tick; the logic enforces it mid-run, and the entry transition
//!   should guard on it too.

use crate::logic::{param_bool, param_f32, LogicFactory, StateCtx, StateLogic};
use crate::vec3::{Vec3, UP, ZERO};

const DEFAULT_MAX_TICKS: f32 = 45.0;
const DEFAULT_SPEED: f32 = 0.15;
/// Cosine of the max wall-normal swing before the run ends (~25 deg).
const MAX_SWING_COS: f32 = 0.9063;
/// Per-tick push into the wall, keeps `contact.wall` true.
const INTO_WALL: f32 = 0.02;

pub struct Wallrun {
    normal: Vec3,
    along: Vec3,
    ticks_left: u32,
    speed: f32,
}

impl Wallrun {
    pub fn new() -> Self {
        Self {
            normal: ZERO,
            along: ZERO,
            ticks_left: 0,
            speed: DEFAULT_SPEED,
        }
    }

    pub fn factory() -> LogicFactory {
        Box::new(|| Box::new(Wallrun::new()))
    }
}

impl Default for Wallrun {
    fn default() -> Self {
        Self::new()
    }
}

impl StateLogic for Wallrun {
    fn on_enter(&mut self, ctx: &mut StateCtx) {
        self.speed = param_f32(ctx.params, "wallrun_speed", DEFAULT_SPEED);
        self.ticks_left =
            param_f32(ctx.params, "wallrun_max_ticks", DEFAULT_MAX_TICKS).max(0.0) as u32;
        if !ctx.contact.wall {
            // Entered without a wall (e.g. behavior entry): on_tick ends the
            // run on the first tick.
            self.normal = ZERO;
            self.along = ZERO;
            self.ticks_left = 0;
            return;
        }
        let n = ctx.contact.wall_normal;
        self.normal = n;
        // Along-wall direction: horizontal facing projected onto the wall
        // plane; deterministic perpendicular fallback.
        let yr = (*ctx.facing_yaw).to_radians();
        let facing = Vec3::new(yr.sin(), 0.0, yr.cos());
        let mut along = facing - n * facing.dot(n);
        along.y = 0.0;
        if along.length() < 1e-4 {
            along = n.cross(UP);
            along.y = 0.0;
        }
        if along.length() < 1e-4 {
            along = Vec3::new(0.0, 0.0, 1.0);
        }
        self.along = along.normalized();
    }

    fn on_tick(&mut self, ctx: &mut StateCtx) {
        let lost = !ctx.contact.wall;
        let swung =
            ctx.contact.wall && self.normal.dot(ctx.contact.wall_normal) < MAX_SWING_COS;
        // Tagged non-runnable wall (game maps its `no_wallrun` group to
        // this param each tick; default true = all walls runnable).
        let disallowed = !param_bool(ctx.params, "wallrun.available", true);
        if lost || swung || disallowed || self.ticks_left == 0 {
            *ctx.delta = ZERO;
            (ctx.fire)("wallrun_end");
            return;
        }
        self.ticks_left -= 1;
        // Run along the wall; pin the running component's height but carry
        // the wall's full velocity (D8 — moving walls drag the player).
        let run = self.along * self.speed;
        let stick = self.normal * (-INTO_WALL);
        let carry = ctx.contact.wall_velocity_per_tick();
        *ctx.delta = Vec3::new(run.x + stick.x, 0.0, run.z + stick.z) + carry;
    }

    fn on_exit(&mut self, _ctx: &mut StateCtx) {}
}
