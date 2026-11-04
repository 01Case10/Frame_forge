//! G-7 built-in: SMG prone crawl (MarioClimb.cpp, verbatim transcription).
//!
//! NOTE: the decomp `MarioClimb` is NOT a wall-climb — it is the **prone
//! crawl** ("匍匐前進" = crawl forward) that plays when Mario pulls himself
//! out of water onto land. Transcribed from
//! `~/workspace/petari/src/Game/Player/MarioClimb.cpp` (see
//! `~/workspace/smg_transcription/marioclimb.md`).
//!
//! `start()` (MarioClimb.cpp:29-37): `mTimer = 15;`
//!
//! `update()` (MarioClimb.cpp:13-27), verbatim:
//! ```cpp
//! bool MarioClimb::update() {
//!     if (mTimer < 15 && checkTrgA()) {
//!         getPlayer()->tryJump();
//!         return false;            // NO addVelocity this tick
//!     }
//!     if (mTimer != 0) {
//!         mTimer--;
//!     }
//!     addVelocity(getFrontVec(), 6.0f);   // accumulating, no decay
//!     if (mTimer == 0) {
//!         return false;            // exit AFTER the 15th addVelocity
//!     }
//!     return true;
//! }
//! ```
//! Per-tick behavior:
//! 1. A press on ticks 2-15 (`mTimer < 15`): jump, exit, and **no**
//!    `addVelocity` runs on that tick (early return). A press on the very
//!    first tick (`mTimer == 15`) is ignored.
//! 2. Otherwise: `mTimer--`, then `velocity += frontVec * 6.0f` —
//!    accumulating, no friction, no gravity, no decay. Unimpeded forward
//!    speed after tick n is `6.0n` (90.0 units/tick on tick 15).
//! 3. Exit when `mTimer == 0` — after exactly 15 ticks of the state.
//!
//! `close()` (MarioClimb.cpp:39-48): `mWalkSpeed = getStickP();` — the
//! handoff: the resumed walk code picks up at the current stick magnitude
//! instead of 0. (The airborne-exit `set3BC(8)` write is not modeled.)
//!
//! Entry (`MarioSwim::close()` → `EXIT_ACTION_SLIDE`) requires water volumes
//! and shore geometry the analytic harness cannot express; entry is out of
//! scope. The state is testable by injecting it directly (the test starts in
//! Crawl via `--start-state`).
//!
//! Params consumed: `smg_walk_speed_param` (default "walk.speed") —
//! blackboard name for the walkSpeed handoff, shared with `smg_physics`.
//! Writes: `smg_crawl_jump=1.0` (A-jump exit), `smg_crawl_done=1.0`
//! (timer-expiry exit).
//!
//! Transitions stay authored (D4): the game/behavior owns state changes;
//! this logic only computes per-tick deltas and raises the exit signals.

use crate::logic::{param_f32, LogicFactory, StateCtx, StateLogic};
use crate::vec3::{Vec3, ZERO};
use std::collections::HashMap;

/// Debug logging for SMG crawl. Enabled via FF_DEBUG=1 env var.
fn dbg_enabled() -> bool {
    std::env::var("FF_DEBUG").map(|v| v == "1").unwrap_or(false)
}
macro_rules! smg_dbg {
    ($($arg:tt)*) => {
        if dbg_enabled() {
            eprintln!($($arg)*);
        }
    };
}

/// SMG units to meters (ff diff compares in meters; 1 SMG unit ≈ 1 cm).
const UNIT_TO_M: f32 = 0.01;

/// State duration in ticks (MarioClimb.cpp:35: `mTimer = 15;`).
const SMG_CRAWL_TICKS: u32 = 15;

/// Per-tick forward velocity addition (MarioClimb.cpp:21:
/// `addVelocity(getFrontVec(), 6.0f)`).
const SMG_CRAWL_SPEED: f32 = 6.0;

fn write_f32(params: &mut HashMap<String, crate::model::ParamValue>, name: &str, v: f32) {
    params.insert(name.to_string(), crate::model::ParamValue::Float(v as f64));
}

pub struct SmgCrawl {
    timer: u32,    // counts down from SMG_CRAWL_TICKS
    velocity: f32, // accumulated forward speed (SMG units/tick)
    walk_speed_param: String,
}

impl SmgCrawl {
    pub fn new() -> Self {
        Self {
            timer: SMG_CRAWL_TICKS,
            velocity: 0.0,
            walk_speed_param: "walk.speed".to_string(),
        }
    }

    pub fn factory() -> LogicFactory {
        Box::new(|| Box::new(SmgCrawl::new()))
    }

    fn facing(&self, ctx: &StateCtx) -> Vec3 {
        let yaw_deg = param_f32(ctx.params, "smg_facing_yaw", *ctx.facing_yaw);
        let yr = yaw_deg.to_radians();
        Vec3::new(yr.sin(), 0.0, yr.cos())
    }
}

impl Default for SmgCrawl {
    fn default() -> Self {
        Self::new()
    }
}

impl StateLogic for SmgCrawl {
    fn on_enter(&mut self, ctx: &mut StateCtx) {
        self.timer = SMG_CRAWL_TICKS;
        self.velocity = 0.0;
        match ctx.params.get("smg_walk_speed_param") {
            Some(crate::model::ParamValue::Str(s)) => self.walk_speed_param = s.clone(),
            _ => self.walk_speed_param = "walk.speed".to_string(),
        }
        // Clear stale exit signals from a previous crawl.
        write_f32(ctx.params, "smg_crawl_jump", 0.0);
        write_f32(ctx.params, "smg_crawl_done", 0.0);
        smg_dbg!("SMG_DBG crawl on_enter frame={}", ctx.frame);
    }

    fn on_tick(&mut self, ctx: &mut StateCtx) {
        // A press on ticks 2-15 (`mTimer < 15 && checkTrgA()`): `tryJump()`
        // and exit — with NO `addVelocity` on this tick (early return).
        // Tick 1 (`mTimer == 15`) ignores A entirely.
        if self.timer < SMG_CRAWL_TICKS && ctx.input.just_pressed.contains("ff_jump") {
            write_f32(ctx.params, "smg_crawl_jump", 1.0);
            *ctx.delta = ZERO;
            smg_dbg!(
                "SMG_DBG crawl frame={}: A jump exit (timer={}), zero delta",
                ctx.frame,
                self.timer
            );
            return;
        }

        // Otherwise: `mTimer--`, then the accumulating velocity addition.
        if self.timer > 0 {
            self.timer -= 1;
        }
        self.velocity += SMG_CRAWL_SPEED;
        *ctx.delta = self.facing(ctx) * (self.velocity * UNIT_TO_M);
        smg_dbg!(
            "SMG_DBG crawl frame={}: timer={} vel={:.2} delta=({:.4},{:.4},{:.4})",
            ctx.frame,
            self.timer,
            self.velocity,
            ctx.delta.x,
            ctx.delta.y,
            ctx.delta.z
        );

        // Exit after the 15th addVelocity (MarioClimb.cpp:23-25).
        if self.timer == 0 {
            write_f32(ctx.params, "smg_crawl_done", 1.0);
        }
    }

    fn on_exit(&mut self, ctx: &mut StateCtx) {
        // close() (MarioClimb.cpp:41): `mWalkSpeed = getStickP();`
        let stick_mag =
            (ctx.stick[0] * ctx.stick[0] + ctx.stick[1] * ctx.stick[1]).sqrt().min(1.0);
        write_f32(ctx.params, &self.walk_speed_param, stick_mag);
        smg_dbg!(
            "SMG_DBG crawl on_exit: walkSpeed handoff {}={:.4}",
            self.walk_speed_param,
            stick_mag
        );
    }
}
